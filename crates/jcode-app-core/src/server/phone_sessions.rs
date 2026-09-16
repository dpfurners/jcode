//! `list_sessions`, `close_session` and `search_files` handlers.
//!
//! These serve the phone session board (see docs/PHONE-WIRE.md). They work on
//! a bare connection, never create a session, and combine live daemon state
//! with on-disk session stubs.

use super::debug::ClientConnectionInfo;
use super::state::{SessionInterruptQueues, SwarmMember, fanout_session_event};
use crate::agent::Agent;
use crate::message::{ContentBlock, Role};
use crate::protocol::{
    FileMatch, PendingPromptInfo, PreviewInfo, RecentProject, ServerEvent, SessionRow,
};
use crate::session::{Session, SessionStatus, StoredMessage};
use chrono::{DateTime, Utc};
use jcode_agent_runtime::InterruptSignal;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, RwLock};

type SessionAgents = Arc<RwLock<HashMap<String, Arc<Mutex<Agent>>>>>;

pub(super) const DEFAULT_LIST_LIMIT: usize = 100;
pub(super) const MAX_RECENT_PROJECTS: usize = 20;
pub(super) const PREVIEW_MAX_CHARS: usize = 240;
pub(super) const DEFAULT_SEARCH_LIMIT: usize = 30;
pub(super) const SEARCH_BUDGET: Duration = Duration::from_millis(500);

// ---------------------------------------------------------------------------
// Pure helpers (unit tested)
// ---------------------------------------------------------------------------

/// Session phase as defined by the phone contract, ordered by priority.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Phase {
    NeedsYou,
    Failed,
    Running,
    Idle,
}

impl Phase {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Phase::NeedsYou => "needs_you",
            Phase::Failed => "failed",
            Phase::Running => "running",
            Phase::Idle => "idle",
        }
    }
}

/// Inputs to phase ranking. Kept as plain booleans so the ranking can be
/// tested without constructing an agent.
#[derive(Debug, Clone, Copy, Default)]
pub(super) struct PhaseInputs {
    pub has_pending_prompt: bool,
    /// The last persisted status is an error/crash and no later turn ran.
    pub last_turn_errored: bool,
    /// A streaming marker exists or a connection reports `is_processing`.
    pub turn_live: bool,
}

/// prompt > error > running > idle.
pub(super) fn rank_phase(inputs: PhaseInputs) -> Phase {
    if inputs.has_pending_prompt {
        Phase::NeedsYou
    } else if inputs.last_turn_errored && !inputs.turn_live {
        Phase::Failed
    } else if inputs.turn_live {
        Phase::Running
    } else {
        Phase::Idle
    }
}

/// Candidate preview texts in the order the contract ranks them:
/// prompt > streaming > assistant > user.
#[derive(Debug, Clone, Default)]
pub(super) struct PreviewCandidates {
    pub prompt: Option<String>,
    pub streaming: Option<String>,
    pub assistant: Option<String>,
    pub user: Option<String>,
}

pub(super) fn pick_preview(candidates: PreviewCandidates) -> Option<PreviewInfo> {
    let pick = |kind: &str, text: Option<String>| {
        text.map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .map(|t| PreviewInfo {
                kind: kind.to_string(),
                text: truncate_preview(&t),
            })
    };
    pick("prompt", candidates.prompt)
        .or_else(|| pick("streaming", candidates.streaming))
        .or_else(|| pick("assistant", candidates.assistant))
        .or_else(|| pick("user", candidates.user))
}

/// Trim to `PREVIEW_MAX_CHARS` characters (not bytes). Streaming previews
/// want the tail; everything else the head. Callers pass the already
/// selected slice, so this just clamps from the front.
pub(super) fn truncate_preview(text: &str) -> String {
    let mut out: String = text.chars().take(PREVIEW_MAX_CHARS).collect();
    if out.len() < text.len() {
        out.push('…');
    }
    out
}

/// Strip `<system-reminder>…</system-reminder>` blocks from user text so the
/// preview never shows injected context.
pub(super) fn strip_system_reminders(text: &str) -> String {
    const OPEN: &str = "<system-reminder>";
    const CLOSE: &str = "</system-reminder>";
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(OPEN) {
        out.push_str(&rest[..start]);
        match rest[start..].find(CLOSE) {
            Some(end) => rest = &rest[start + end + CLOSE.len()..],
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    out.trim().to_string()
}

fn message_text(message: &StoredMessage) -> String {
    message
        .content
        .iter()
        .filter_map(|block| match block {
            ContentBlock::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Assistant and user preview candidates from a message list.
fn transcript_previews(messages: &[StoredMessage]) -> (Option<String>, Option<String>) {
    let assistant = messages
        .iter()
        .rev()
        .filter(|m| m.role == Role::Assistant)
        .map(message_text)
        .find(|t| !t.trim().is_empty());
    let user = messages
        .iter()
        .rev()
        .filter(|m| m.role == Role::User)
        .map(|m| strip_system_reminders(&message_text(m)))
        .find(|t| !t.trim().is_empty());
    (assistant, user)
}

fn rfc3339(ts: DateTime<Utc>) -> String {
    ts.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn system_time_rfc3339(time: std::time::SystemTime) -> String {
    rfc3339(DateTime::<Utc>::from(time))
}

fn status_error(status: &SessionStatus) -> Option<String> {
    match status {
        SessionStatus::Error { message } => Some(message.clone()),
        SessionStatus::Crashed { message } => {
            Some(message.clone().unwrap_or_else(|| "crashed".to_string()))
        }
        _ => None,
    }
}

/// Build `recent_projects`: pins first, then distinct working dirs over the
/// listed rows (already newest first), capped at `MAX_RECENT_PROJECTS`.
pub(super) fn recent_projects(pins: &[String], rows: &[SessionRow]) -> Vec<RecentProject> {
    let mut out: Vec<RecentProject> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for pin in pins {
        let pin = pin.trim();
        if pin.is_empty() || index.contains_key(pin) {
            continue;
        }
        index.insert(pin.to_string(), out.len());
        out.push(RecentProject {
            path: pin.to_string(),
            last_used_at: None,
            session_count: 0,
        });
    }
    for row in rows {
        let Some(dir) = row.working_dir.as_deref() else {
            continue;
        };
        let used = row
            .last_active_at
            .clone()
            .unwrap_or_else(|| row.updated_at.clone());
        match index.get(dir) {
            Some(&i) => {
                out[i].session_count += 1;
                if out[i]
                    .last_used_at
                    .as_deref()
                    .is_none_or(|prev| used.as_str() > prev)
                {
                    out[i].last_used_at = Some(used);
                }
            }
            None => {
                if out.len() >= MAX_RECENT_PROJECTS {
                    continue;
                }
                index.insert(dir.to_string(), out.len());
                out.push(RecentProject {
                    path: dir.to_string(),
                    last_used_at: Some(used),
                    session_count: 1,
                });
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// list_sessions
// ---------------------------------------------------------------------------

/// Session ids present on disk, from `<jcode_home>/sessions/*.json`.
pub(super) fn on_disk_session_ids() -> Vec<String> {
    let Ok(base) = crate::storage::jcode_dir() else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(base.join("sessions")) else {
        return Vec::new();
    };
    entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            let stem = name.strip_suffix(".json")?;
            if stem.ends_with(".journal") || !stem.starts_with("session_") {
                return None;
            }
            Some(stem.to_string())
        })
        .collect()
}

/// Streaming marker birth time for a session, if a turn is live.
fn streaming_since(session_id: &str) -> Option<std::time::SystemTime> {
    let dir = crate::storage::streaming_pids_dir()?;
    let meta = std::fs::metadata(dir.join(session_id)).ok()?;
    meta.created().or_else(|_| meta.modified()).ok()
}

#[derive(Debug, Clone, Default)]
struct LiveInfo {
    is_processing: bool,
    current_tool: Option<String>,
    client_count: usize,
}

/// Per-session aggregate of the attached client connections.
fn live_info_by_session(
    connections: &HashMap<String, ClientConnectionInfo>,
) -> HashMap<String, LiveInfo> {
    let mut out: HashMap<String, LiveInfo> = HashMap::new();
    for conn in connections.values() {
        let info = out.entry(conn.session_id.clone()).or_default();
        info.client_count += 1;
        info.is_processing |= conn.is_processing;
        if info.current_tool.is_none() {
            info.current_tool = conn.current_tool_name.clone();
        }
    }
    out
}

fn row_from_session(
    session: &Session,
    live: LiveInfo,
    is_live: bool,
    queued: usize,
    swarm_role: Option<String>,
    provider: Option<String>,
    previews: (Option<String>, Option<String>),
    pending_prompt: Option<PendingPromptInfo>,
) -> SessionRow {
    let streaming = streaming_since(&session.id);
    let turn_live = streaming.is_some() || live.is_processing;
    let last_error = status_error(&session.status);
    let phase = rank_phase(PhaseInputs {
        has_pending_prompt: pending_prompt.is_some(),
        last_turn_errored: last_error.is_some(),
        turn_live,
    });
    let reason = match phase {
        Phase::NeedsYou => Some("waiting for input".to_string()),
        Phase::Failed => last_error,
        _ => None,
    };
    let current_tool = match phase {
        Phase::Running | Phase::NeedsYou => live.current_tool,
        _ => None,
    };
    let preview = pick_preview(PreviewCandidates {
        prompt: pending_prompt.as_ref().map(|p| p.prompt.clone()),
        streaming: None,
        assistant: previews.0,
        user: previews.1,
    });
    SessionRow {
        id: session.id.clone(),
        short_name: session.short_name.clone(),
        title: session
            .custom_title
            .clone()
            .or_else(|| session.title.clone()),
        working_dir: session.working_dir.clone(),
        created_at: rfc3339(session.created_at),
        updated_at: rfc3339(session.updated_at),
        last_active_at: session.last_active_at.map(rfc3339),
        model: session.model.clone(),
        provider,
        phase: phase.as_str().to_string(),
        reason,
        current_tool,
        turn_started_at: if turn_live {
            streaming.map(system_time_rfc3339)
        } else {
            None
        },
        queued,
        pending_prompt,
        preview,
        client_count: live.client_count,
        is_live,
        parent_id: session.parent_id.clone(),
        swarm_role,
    }
}

fn swarm_role_of(member: Option<&SwarmMember>) -> Option<String> {
    let member = member?;
    member.swarm_id.as_ref()?;
    if member.role == "coordinator" {
        Some("coordinator".to_string())
    } else if member.is_headless || member.report_back_to_session_id.is_some() {
        Some("worker".to_string())
    } else {
        None
    }
}

pub(super) struct ListSessionsContext<'a> {
    pub sessions: &'a SessionAgents,
    pub client_connections: &'a Arc<RwLock<HashMap<String, ClientConnectionInfo>>>,
    pub soft_interrupt_queues: &'a SessionInterruptQueues,
    pub swarm_members: &'a Arc<RwLock<HashMap<String, SwarmMember>>>,
    /// The per-session stdin prompt store. `None` on paths that do not
    /// carry it (the debug socket's `sessions` command), where every row
    /// reports no prompt.
    pub pending_prompts: Option<&'a super::PendingPromptStore>,
    pub server_name: &'a str,
    pub server_icon: &'a str,
}

/// Build the `sessions` event. Live agents win over on-disk stubs. Previews
/// for non-live rows are read from the full session file only for the top
/// `limit` rows (the stub does not carry messages).
pub(super) async fn build_sessions_event(
    id: u64,
    limit: Option<usize>,
    include_workers: bool,
    ctx: ListSessionsContext<'_>,
) -> ServerEvent {
    let limit = limit.unwrap_or(DEFAULT_LIST_LIMIT).max(1);
    let live_infos = live_info_by_session(&*ctx.client_connections.read().await);
    let prompts: HashMap<String, PendingPromptInfo> = match ctx.pending_prompts {
        Some(store) => store.snapshot().await,
        None => HashMap::new(),
    };
    let members = ctx.swarm_members.read().await;
    let live_agents: Vec<(String, Arc<Mutex<Agent>>)> = ctx
        .sessions
        .read()
        .await
        .iter()
        .map(|(k, v)| (k.clone(), Arc::clone(v)))
        .collect();
    let queues = ctx.soft_interrupt_queues.read().await;
    let queued_for = |sid: &str| -> usize {
        queues
            .get(sid)
            .and_then(|q| q.lock().ok().map(|v| v.len()))
            .unwrap_or(0)
    };

    let is_wanted = |session: &Session, role: &Option<String>| -> bool {
        if session.is_debug {
            return false;
        }
        if session.parent_id.is_none() {
            return true;
        }
        include_workers && role.is_some()
    };

    let mut rows: Vec<SessionRow> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let on_disk: HashSet<String> = on_disk_session_ids().into_iter().collect();

    for (sid, agent_arc) in live_agents {
        // A busy agent holds its lock for the whole turn. Do not wait on it:
        // fall back to the on-disk stub for that row instead of stalling the
        // board.
        let Ok(agent) = agent_arc.try_lock() else {
            continue;
        };
        let session = agent.session_for_split();
        let role = swarm_role_of(members.get(&sid));
        if !is_wanted(session, &role) {
            seen.insert(sid.clone());
            continue;
        }
        let previews = transcript_previews(&session.messages);
        // A live session nobody has spoken to and that was never saved is a
        // connection artefact: every `subscribe` without a target creates
        // one (a tool-catalog probe, a client that attached and moved on),
        // and the daemon retains it a while for reconnect grace. Listing it
        // put a phantom idle row on every board within seconds of opening a
        // tab. Once a user message or a save exists it is a real session.
        if previews.1.is_none() && !on_disk.contains(&sid) {
            seen.insert(sid.clone());
            continue;
        }
        let row = row_from_session(
            session,
            live_infos.get(&sid).cloned().unwrap_or_default(),
            true,
            queued_for(&sid),
            role,
            Some(agent.provider_name()),
            previews,
            prompts.get(&sid).cloned(),
        );
        seen.insert(sid);
        rows.push(row);
    }

    // On-disk stubs for everything else (including live-but-busy agents).
    let live_ids: HashSet<String> = ctx.sessions.read().await.keys().cloned().collect();
    let mut stub_rows: Vec<SessionRow> = Vec::new();
    for sid in on_disk.iter().cloned() {
        if seen.contains(&sid) {
            continue;
        }
        let Ok(session) = Session::load_startup_stub(&sid) else {
            continue;
        };
        let role = swarm_role_of(members.get(&sid));
        if !is_wanted(&session, &role) {
            continue;
        }
        let is_live = live_ids.contains(&sid);
        let row = row_from_session(
            &session,
            live_infos.get(&sid).cloned().unwrap_or_default(),
            is_live,
            queued_for(&sid),
            role,
            session.provider_key.clone(),
            (None, None),
            prompts.get(&sid).cloned(),
        );
        stub_rows.push(row);
    }
    drop(queues);
    drop(members);

    rows.extend(stub_rows);
    rows.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
    rows.truncate(limit);

    // Preview cost: rows built from stubs have no transcript. Load the full
    // session file for those top rows only.
    for row in rows.iter_mut().filter(|r| r.preview.is_none()) {
        if let Ok(session) = Session::load(&row.id) {
            let previews = transcript_previews(&session.messages);
            row.preview = pick_preview(PreviewCandidates {
                assistant: previews.0,
                user: previews.1,
                ..Default::default()
            });
        }
    }

    let pins = crate::config::config().phone.pinned_projects.clone();
    let recent = recent_projects(&pins, &rows);

    ServerEvent::Sessions {
        id,
        server_name: ctx.server_name.to_string(),
        server_icon: ctx.server_icon.to_string(),
        server_version: jcode_build_meta::version().to_string(),
        sessions: rows,
        recent_projects: recent,
    }
}

// ---------------------------------------------------------------------------
// close_session
// ---------------------------------------------------------------------------

pub(super) struct CloseSessionContext<'a> {
    pub sessions: &'a SessionAgents,
    pub shutdown_signals: &'a Arc<RwLock<HashMap<String, InterruptSignal>>>,
    pub soft_interrupt_queues: &'a SessionInterruptQueues,
    pub swarm_members: &'a Arc<RwLock<HashMap<String, SwarmMember>>>,
}

/// Cancel a live turn, ask every attached client to close, unload the agent
/// and optionally delete the session file. Returns the event to reply with.
pub(super) async fn close_session(
    id: u64,
    session_id: &str,
    delete: bool,
    ctx: CloseSessionContext<'_>,
) -> ServerEvent {
    let known = ctx.sessions.read().await.contains_key(session_id)
        || crate::session::session_exists(session_id);
    if !known {
        return ServerEvent::Error {
            id,
            message: format!("Unknown session '{session_id}'"),
            retry_after_secs: None,
        };
    }

    if let Some(signal) = ctx.shutdown_signals.read().await.get(session_id) {
        signal.fire();
    }
    super::state::remove_background_tool_signal(session_id);

    let _ = fanout_session_event(
        ctx.swarm_members,
        session_id,
        ServerEvent::SessionCloseRequested {
            reason: if delete {
                "Session deleted from the session board".to_string()
            } else {
                "Session closed from the session board".to_string()
            },
        },
    )
    .await;

    if let Some(agent_arc) = super::remove_session_entry(ctx.sessions, session_id).await {
        super::state::remove_session_interrupt_queue(ctx.soft_interrupt_queues, session_id).await;
        if let Ok(mut agent) = agent_arc.try_lock() {
            agent.mark_closed();
        }
    }
    ctx.shutdown_signals.write().await.remove(session_id);

    let mut deleted = false;
    if delete && let Ok(path) = crate::session::session_path(session_id) {
        deleted = std::fs::remove_file(&path).is_ok();
        let _ = std::fs::remove_file(crate::session::session_journal_path_from_snapshot(&path));
    }

    ServerEvent::SessionClosed {
        id,
        session_id: session_id.to_string(),
        deleted,
    }
}

// ---------------------------------------------------------------------------
// search_files
// ---------------------------------------------------------------------------

/// Score a candidate against `query`. Higher is better; `None` is no match.
/// prefix > contains > subsequence. Case-insensitive.
pub(super) fn match_score(candidate: &str, query: &str) -> Option<u32> {
    if query.is_empty() {
        return Some(0);
    }
    let candidate_lc = candidate.to_lowercase();
    let query_lc = query.to_lowercase();
    let file_name = candidate_lc.rsplit('/').next().unwrap_or(&candidate_lc);
    if file_name.starts_with(&query_lc) {
        return Some(300);
    }
    if candidate_lc.starts_with(&query_lc) {
        return Some(250);
    }
    if file_name.contains(&query_lc) {
        return Some(200);
    }
    if candidate_lc.contains(&query_lc) {
        return Some(150);
    }
    let mut chars = query_lc.chars();
    let mut needle = chars.next();
    let mut gaps = 0u32;
    for c in candidate_lc.chars() {
        match needle {
            Some(n) if n == c => needle = chars.next(),
            Some(_) => gaps += 1,
            None => break,
        }
        if needle.is_none() {
            break;
        }
    }
    if needle.is_none() {
        Some(100u32.saturating_sub(gaps.min(99)))
    } else {
        None
    }
}

/// Fuzzy search under `root`, honouring `.gitignore`, skipping `.git`,
/// never following symlinks, bounded by `SEARCH_BUDGET`.
pub(super) fn search_relative(
    root: &Path,
    query: &str,
    limit: usize,
    dirs_only: bool,
) -> Vec<FileMatch> {
    let started = Instant::now();
    let mut scored: Vec<(u32, FileMatch)> = Vec::new();
    let walker = ignore::WalkBuilder::new(root)
        .hidden(false)
        .follow_links(false)
        .git_ignore(true)
        .git_global(true)
        .git_exclude(true)
        .filter_entry(|entry| entry.file_name() != ".git")
        .build();
    for entry in walker {
        if started.elapsed() > SEARCH_BUDGET {
            break;
        }
        let Ok(entry) = entry else {
            continue;
        };
        if entry.depth() == 0 {
            continue;
        }
        let is_dir = entry.file_type().is_some_and(|t| t.is_dir());
        if dirs_only && !is_dir {
            continue;
        }
        let Ok(rel) = entry.path().strip_prefix(root) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        if let Some(score) = match_score(&rel, query) {
            // Shorter paths first among equal scores.
            scored.push((score, FileMatch { path: rel, is_dir }));
        }
    }
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| a.1.path.len().cmp(&b.1.path.len()))
            .then_with(|| a.1.path.cmp(&b.1.path))
    });
    scored.into_iter().map(|(_, m)| m).take(limit).collect()
}

/// Absolute path-prefix completion: list entries of the parent directory
/// whose name starts with the last component. Paths returned absolute.
pub(super) fn search_absolute(query: &str, limit: usize, dirs_only: bool) -> Vec<FileMatch> {
    let (parent, prefix): (PathBuf, String) = if query.ends_with('/') {
        (PathBuf::from(query), String::new())
    } else {
        let path = Path::new(query);
        let parent = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("/"));
        let prefix = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        (parent, prefix)
    };
    let Ok(entries) = std::fs::read_dir(&parent) else {
        return Vec::new();
    };
    let prefix_lc = prefix.to_lowercase();
    let mut matches: Vec<FileMatch> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().to_string();
            if name == ".git" || !name.to_lowercase().starts_with(&prefix_lc) {
                return None;
            }
            // Do not follow symlinks: classify by the link itself.
            let is_dir = entry.file_type().ok()?.is_dir();
            if dirs_only && !is_dir {
                return None;
            }
            let mut path = parent.join(&name).to_string_lossy().to_string();
            if is_dir && !path.ends_with('/') {
                path.push('/');
            }
            Some(FileMatch { path, is_dir })
        })
        .collect();
    matches.sort_by(|a, b| {
        // Non-hidden first, then directories, then name.
        let a_hidden = a
            .path
            .rsplit('/')
            .find(|s| !s.is_empty())
            .is_some_and(|n| n.starts_with('.'));
        let b_hidden = b
            .path
            .rsplit('/')
            .find(|s| !s.is_empty())
            .is_some_and(|n| n.starts_with('.'));
        a_hidden
            .cmp(&b_hidden)
            .then_with(|| b.is_dir.cmp(&a.is_dir))
            .then_with(|| a.path.cmp(&b.path))
    });
    matches.truncate(limit);
    matches
}

/// Build the `file_matches` event. `working_dir` must already be resolved.
pub(super) async fn build_file_matches_event(
    id: u64,
    query: &str,
    limit: Option<usize>,
    dirs_only: bool,
    working_dir: Option<&str>,
) -> ServerEvent {
    let limit = limit.unwrap_or(DEFAULT_SEARCH_LIMIT).max(1);
    if query.starts_with('/') {
        return ServerEvent::FileMatches {
            id,
            query: query.to_string(),
            matches: search_absolute(query, limit, dirs_only),
        };
    }
    let Some(working_dir) = working_dir else {
        return ServerEvent::Error {
            id,
            message: "search_files needs working_dir on a connection without a session".to_string(),
            retry_after_secs: None,
        };
    };
    let root = Path::new(working_dir);
    if !root.is_dir() {
        return ServerEvent::Error {
            id,
            message: format!("search_files: working_dir '{working_dir}' is not a directory"),
            retry_after_secs: None,
        };
    }
    // The walk is filesystem-bound and budgeted at 500 ms; keep it off the
    // async workers so a slow disk never stalls other connections.
    let root = root.to_path_buf();
    let owned_query = query.to_string();
    let matches =
        tokio::task::spawn_blocking(move || search_relative(&root, &owned_query, limit, dirs_only))
            .await
            .unwrap_or_default();
    ServerEvent::FileMatches {
        id,
        query: query.to_string(),
        matches,
    }
}

#[cfg(test)]
#[path = "phone_sessions_tests.rs"]
mod tests;
