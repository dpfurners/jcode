//! End-to-end tests for the phone session-board requests over a real
//! client/server stream pair, without `subscribe`.

use super::*;
use crate::message::{Message, ToolDefinition};
use crate::provider::{EventStream, Provider};
use async_trait::async_trait;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

struct PanicOnForkProvider {
    forked: Arc<AtomicBool>,
}

#[async_trait]
impl Provider for PanicOnForkProvider {
    async fn complete(
        &self,
        _messages: &[Message],
        _tools: &[ToolDefinition],
        _system: &str,
        _resume_session_id: Option<&str>,
    ) -> Result<EventStream> {
        panic!("board requests must never run a model turn");
    }

    fn name(&self) -> &str {
        "panic-on-fork"
    }

    fn fork(&self) -> Arc<dyn Provider> {
        self.forked.store(true, Ordering::SeqCst);
        Arc::new(Self {
            forked: Arc::clone(&self.forked),
        })
    }
}

struct IsolatedHome {
    prev_home: Option<std::ffi::OsString>,
    prev_runtime: Option<std::ffi::OsString>,
    _home: tempfile::TempDir,
    _runtime: tempfile::TempDir,
}

impl IsolatedHome {
    fn new() -> Self {
        let home = tempfile::TempDir::new().expect("jcode home");
        let runtime = tempfile::TempDir::new().expect("runtime dir");
        let prev_home = std::env::var_os("JCODE_HOME");
        let prev_runtime = std::env::var_os("JCODE_RUNTIME_DIR");
        crate::env::set_var("JCODE_HOME", home.path());
        crate::env::set_var("JCODE_RUNTIME_DIR", runtime.path());
        Self {
            prev_home,
            prev_runtime,
            _home: home,
            _runtime: runtime,
        }
    }
}

impl Drop for IsolatedHome {
    fn drop(&mut self) {
        match self.prev_home.take() {
            Some(prev) => crate::env::set_var("JCODE_HOME", prev),
            None => crate::env::remove_var("JCODE_HOME"),
        }
        match self.prev_runtime.take() {
            Some(prev) => crate::env::set_var("JCODE_RUNTIME_DIR", prev),
            None => crate::env::remove_var("JCODE_RUNTIME_DIR"),
        }
    }
}

struct Harness {
    sessions: SessionAgents,
    swarm_members: Arc<RwLock<HashMap<String, SwarmMember>>>,
    shutdown_signals: Arc<RwLock<HashMap<String, InterruptSignal>>>,
    forked: Arc<AtomicBool>,
}

impl Harness {
    fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            swarm_members: Arc::new(RwLock::new(HashMap::new())),
            shutdown_signals: Arc::new(RwLock::new(HashMap::new())),
            forked: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Spawn `handle_client` on a fresh stream pair and return the client
    /// half plus the server task.
    fn connect(
        &self,
    ) -> (
        crate::transport::Stream,
        tokio::task::JoinHandle<Result<()>>,
    ) {
        let (server_stream, client_stream) =
            crate::transport::Stream::pair().expect("socket pair");
        let provider_template: Arc<dyn Provider> = Arc::new(PanicOnForkProvider {
            forked: Arc::clone(&self.forked),
        });
        let (_debug_response_tx, _) = broadcast::channel(8);
        let (swarm_event_tx, _) = broadcast::channel(8);
        let (_global_event_tx, _) = broadcast::channel(8);
        let task = tokio::spawn(handle_client(
            server_stream,
            Arc::clone(&self.sessions),
            _global_event_tx,
            provider_template,
            Arc::new(RwLock::new(false)),
            Arc::new(RwLock::new(String::new())),
            Arc::new(RwLock::new(0usize)),
            Arc::new(RwLock::new(HashMap::new())),
            Arc::clone(&self.swarm_members),
            Arc::new(RwLock::new(HashMap::new())),
            Arc::new(RwLock::new(HashMap::new())),
            Arc::new(RwLock::new(HashMap::new())),
            Arc::new(RwLock::new(HashMap::new())),
            FileTouchService::new(),
            Arc::new(RwLock::new(HashMap::new())),
            Arc::new(RwLock::new(HashMap::new())),
            Arc::new(RwLock::new(ClientDebugState::default())),
            _debug_response_tx,
            Arc::new(RwLock::new(std::collections::VecDeque::new())),
            Arc::new(std::sync::atomic::AtomicU64::new(0)),
            swarm_event_tx,
            "jcode-test".to_string(),
            "🧪".to_string(),
            Arc::new(crate::mcp::SharedMcpPool::from_default_config()),
            Arc::clone(&self.shutdown_signals),
            Arc::new(RwLock::new(HashMap::new())),
            AwaitMembersRuntime::default(),
            SwarmMutationRuntime::default(),
        ));
        (client_stream, task)
    }
}

async fn roundtrip(client: crate::transport::Stream, request: &Request) -> ServerEvent {
    let (reader, mut writer) = client.into_split();
    let mut reader = BufReader::new(reader);
    let payload = serde_json::to_string(request).expect("serialize") + "\n";
    writer.write_all(payload.as_bytes()).await.expect("write");
    let mut line = String::new();
    tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
        .await
        .expect("reply within 5s")
        .expect("read reply");
    serde_json::from_str(line.trim()).expect("decode server event")
}

/// Persist a session with one visible user message (an empty untitled
/// session is intentionally never written to disk).
fn persist_session(id: &str, working_dir: &str, title: Option<&str>) {
    let mut session = crate::session::Session::create_with_id(id.to_string(), None, None);
    session.working_dir = Some(working_dir.to_string());
    session.title = title.map(str::to_string);
    session.add_message(
        crate::message::Role::User,
        vec![crate::message::ContentBlock::Text {
            text: format!("hello from {id} <system-reminder>hidden</system-reminder>"),
            cache_control: None,
        }],
    );
    session.save().expect("save session");
}

#[tokio::test]
async fn list_sessions_on_bare_connection_lists_disk_sessions_without_creating_one() {
    let _guard = crate::storage::lock_test_env();
    let _home = IsolatedHome::new();
    persist_session("session_alpha_1_a", "/tmp/alpha", Some("Alpha work"));
    persist_session("session_beta_2_b", "/tmp/beta", None);
    // A child session must not appear in the default listing.
    let mut child = crate::session::Session::create_with_id(
        "session_child_3_c".to_string(),
        Some("session_alpha_1_a".to_string()),
        None,
    );
    child.working_dir = Some("/tmp/alpha".to_string());
    child.save().expect("save child");

    let harness = Harness::new();
    let (client, task) = harness.connect();
    let event = roundtrip(
        client,
        &Request::ListSessions {
            id: 7,
            limit: None,
            include_workers: false,
        },
    )
    .await;

    let ServerEvent::Sessions {
        id,
        server_name,
        sessions,
        recent_projects,
        ..
    } = event
    else {
        panic!("expected sessions event, got {event:?}");
    };
    assert_eq!(id, 7);
    assert_eq!(server_name, "jcode-test");
    let ids: Vec<&str> = sessions.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids.len(), 2, "{ids:?}");
    assert!(ids.contains(&"session_alpha_1_a"));
    assert!(ids.contains(&"session_beta_2_b"));
    let alpha = sessions
        .iter()
        .find(|s| s.id == "session_alpha_1_a")
        .unwrap();
    assert_eq!(alpha.title.as_deref(), Some("Alpha work"));
    assert_eq!(alpha.phase, "idle");
    assert!(!alpha.is_live);
    assert!(alpha.pending_prompt.is_none());
    let preview = alpha.preview.as_ref().expect("preview from transcript");
    assert_eq!(preview.kind, "user");
    assert_eq!(preview.text, "hello from session_alpha_1_a");
    let paths: Vec<&str> = recent_projects.iter().map(|p| p.path.as_str()).collect();
    assert!(paths.contains(&"/tmp/alpha") && paths.contains(&"/tmp/beta"), "{paths:?}");

    // No throwaway session was created in memory or on disk.
    assert!(harness.sessions.read().await.is_empty());
    assert_eq!(crate::server::phone_sessions::on_disk_session_ids().len(), 3);
    assert!(!harness.forked.load(Ordering::SeqCst));
    task.await.expect("join").expect("server task");
}

#[tokio::test]
async fn close_session_notifies_attached_client_and_unloads_agent() {
    let _guard = crate::storage::lock_test_env();
    let _home = IsolatedHome::new();
    let sid = "session_close_4_d";
    persist_session(sid, "/tmp/close", None);

    let harness = Harness::new();
    // A live agent for the session, attached through a swarm member sender.
    let provider: Arc<dyn Provider> = Arc::new(PanicOnForkProvider {
        forked: Arc::clone(&harness.forked),
    });
    let registry = Registry::new(Arc::clone(&provider)).await;
    let session = crate::session::Session::load(sid).expect("load");
    let agent = Agent::new_with_session(provider, registry, session, None);
    harness
        .sessions
        .write()
        .await
        .insert(sid.to_string(), Arc::new(Mutex::new(agent)));
    let signal = InterruptSignal::new();
    harness
        .shutdown_signals
        .write()
        .await
        .insert(sid.to_string(), signal.clone());
    let (event_tx, mut event_rx) = mpsc::unbounded_channel();
    harness.swarm_members.write().await.insert(
        sid.to_string(),
        SwarmMember {
            session_id: sid.to_string(),
            event_tx,
            event_txs: HashMap::new(),
            working_dir: None,
            swarm_id: None,
            swarm_enabled: false,
            status: "ready".to_string(),
            detail: None,
            friendly_name: None,
            report_back_to_session_id: None,
            latest_completion_report: None,
            role: "agent".to_string(),
            joined_at: Instant::now(),
            last_status_change: Instant::now(),
            is_headless: false,
            output_tail: None,
            todo_progress: None,
            todo_items: Vec::new(),
            runtime: crate::protocol::SwarmMemberRuntime::default(),
            task_label: None,
        },
    );

    let (client, task) = harness.connect();
    let event = roundtrip(
        client,
        &Request::CloseSession {
            id: 8,
            session_id: sid.to_string(),
            delete: false,
        },
    )
    .await;
    assert!(
        matches!(
            &event,
            ServerEvent::SessionClosed { id: 8, session_id, deleted: false } if session_id == sid
        ),
        "{event:?}"
    );
    assert!(signal.is_set(), "live turn must be cancelled");
    assert!(
        !harness.sessions.read().await.contains_key(sid),
        "agent must be unloaded"
    );
    let notified = event_rx.try_recv().expect("attached client gets an event");
    assert!(
        matches!(notified, ServerEvent::SessionCloseRequested { .. }),
        "{notified:?}"
    );
    assert!(crate::session::session_exists(sid), "delete=false keeps the file");
    task.await.expect("join").expect("server task");

    // delete=true removes the file; unknown id afterwards is an error.
    let (client, task) = harness.connect();
    let event = roundtrip(
        client,
        &Request::CloseSession {
            id: 9,
            session_id: sid.to_string(),
            delete: true,
        },
    )
    .await;
    assert!(
        matches!(event, ServerEvent::SessionClosed { deleted: true, .. }),
        "{event:?}"
    );
    assert!(!crate::session::session_exists(sid));
    task.await.expect("join").expect("server task");

    let (client, task) = harness.connect();
    let event = roundtrip(
        client,
        &Request::CloseSession {
            id: 10,
            session_id: sid.to_string(),
            delete: false,
        },
    )
    .await;
    assert!(matches!(event, ServerEvent::Error { id: 10, .. }), "{event:?}");
    task.await.expect("join").expect("server task");
}

#[tokio::test]
async fn search_files_on_bare_connection_honours_gitignore() {
    let _guard = crate::storage::lock_test_env();
    let _home = IsolatedHome::new();
    let project = tempfile::tempdir().expect("project");
    let root = project.path();
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::create_dir_all(root.join("src/views")).unwrap();
    std::fs::create_dir_all(root.join("build")).unwrap();
    std::fs::write(root.join("src/views/ComposerView.swift"), "").unwrap();
    std::fs::write(root.join("build/ComposerGen.swift"), "").unwrap();
    std::fs::write(root.join(".gitignore"), "build/\n").unwrap();

    let harness = Harness::new();
    let (client, task) = harness.connect();
    let event = roundtrip(
        client,
        &Request::SearchFiles {
            id: 9,
            query: "compos".to_string(),
            limit: Some(30),
            dirs_only: false,
            working_dir: Some(root.to_string_lossy().to_string()),
        },
    )
    .await;
    let ServerEvent::FileMatches { id, query, matches } = event else {
        panic!("expected file_matches, got {event:?}");
    };
    assert_eq!((id, query.as_str()), (9, "compos"));
    let paths: Vec<&str> = matches.iter().map(|m| m.path.as_str()).collect();
    assert_eq!(paths, vec!["src/views/ComposerView.swift"], "{paths:?}");
    task.await.expect("join").expect("server task");

    // Without a working_dir a bare connection gets an error, not a session.
    let (client, task) = harness.connect();
    let event = roundtrip(
        client,
        &Request::SearchFiles {
            id: 11,
            query: "compos".to_string(),
            limit: None,
            dirs_only: false,
            working_dir: None,
        },
    )
    .await;
    assert!(matches!(event, ServerEvent::Error { id: 11, .. }), "{event:?}");
    assert!(harness.sessions.read().await.is_empty());
    task.await.expect("join").expect("server task");
}
