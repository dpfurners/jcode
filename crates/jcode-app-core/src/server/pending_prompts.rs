//! Server-wide store of stdin prompts that are waiting for a user answer.
//!
//! A running tool (e.g. `bash` executing `read -r x`) asks for input through
//! `StdinInputRequest`. Historically the responder lived in the map of the
//! connection that happened to be attached when the tool started, so a client
//! that reconnected (or a second client attached to the same session) could
//! neither see nor answer the prompt. This store keys pending prompts by
//! session id so any attached client can answer, late subscribers get the
//! prompt replayed after `history`, and the other clients learn when it was
//! resolved.

use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::{Mutex, RwLock, oneshot};

use crate::protocol::ServerEvent;

/// A prompt that is waiting for an answer.
pub struct PendingPrompt {
    pub request_id: String,
    pub prompt: String,
    pub is_password: bool,
    pub tool_call_id: String,
    /// Taken exactly once by whichever client answers first.
    pub response_tx: Mutex<Option<oneshot::Sender<String>>>,
}

/// Read-only snapshot of a pending prompt (for `list_sessions` and replay).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingPromptInfo {
    pub request_id: String,
    pub prompt: String,
    pub is_password: bool,
    pub tool_call_id: String,
}

impl PendingPromptInfo {
    pub fn to_event(&self) -> ServerEvent {
        ServerEvent::StdinRequest {
            request_id: self.request_id.clone(),
            prompt: self.prompt.clone(),
            is_password: self.is_password,
            tool_call_id: self.tool_call_id.clone(),
        }
    }
}

/// `session_id -> PendingPrompt`. One prompt per session at a time: the bash
/// stdin loop is sequential, and a second request for the same session
/// replaces the first (whose sender is dropped, unblocking that tool).
#[derive(Clone, Default)]
pub struct PendingPromptStore {
    inner: Arc<RwLock<HashMap<String, Arc<PendingPrompt>>>>,
}

impl PendingPromptStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a prompt for `session_id`. Returns the replay-able snapshot.
    pub async fn register(
        &self,
        session_id: &str,
        request_id: String,
        prompt: String,
        is_password: bool,
        tool_call_id: String,
        response_tx: oneshot::Sender<String>,
    ) -> PendingPromptInfo {
        let entry = Arc::new(PendingPrompt {
            request_id: request_id.clone(),
            prompt: prompt.clone(),
            is_password,
            tool_call_id: tool_call_id.clone(),
            response_tx: Mutex::new(Some(response_tx)),
        });
        self.inner
            .write()
            .await
            .insert(session_id.to_string(), entry);
        PendingPromptInfo {
            request_id,
            prompt,
            is_password,
            tool_call_id,
        }
    }

    /// Snapshot of the prompt currently pending for `session_id`, if any.
    ///
    /// Used by subscribe/resume replay and by the `list_sessions`
    /// `pending_prompt` field so every reader sees the same store.
    /// Every pending prompt, keyed by session id, in the wire's shape: what
    /// `list_sessions` puts into each row's `pending_prompt`.
    pub async fn snapshot(&self) -> HashMap<String, crate::protocol::PendingPromptInfo> {
        self.inner
            .read()
            .await
            .iter()
            .map(|(sid, entry)| {
                (
                    sid.clone(),
                    crate::protocol::PendingPromptInfo {
                        request_id: entry.request_id.clone(),
                        prompt: entry.prompt.clone(),
                        is_password: entry.is_password,
                        tool_call_id: Some(entry.tool_call_id.clone()),
                    },
                )
            })
            .collect()
    }

    pub async fn pending_prompt_for(&self, session_id: &str) -> Option<PendingPromptInfo> {
        let map = self.inner.read().await;
        let entry = map.get(session_id)?;
        Some(PendingPromptInfo {
            request_id: entry.request_id.clone(),
            prompt: entry.prompt.clone(),
            is_password: entry.is_password,
            tool_call_id: entry.tool_call_id.clone(),
        })
    }

    /// Find the session that owns `request_id`.
    pub async fn session_for_request(&self, request_id: &str) -> Option<String> {
        self.inner
            .read()
            .await
            .iter()
            .find(|(_, entry)| entry.request_id == request_id)
            .map(|(session_id, _)| session_id.clone())
    }

    /// Answer the prompt identified by `request_id`. Returns the owning
    /// session id when an unanswered entry was found and the answer was
    /// delivered to the tool.
    pub async fn resolve(&self, request_id: &str, input: String) -> Option<String> {
        let session_id = self.session_for_request(request_id).await?;
        let entry = self.inner.write().await.remove(&session_id)?;
        let tx = entry.response_tx.lock().await.take()?;
        let _ = tx.send(input);
        Some(session_id)
    }

    /// Drop the prompt for `request_id` without answering (tool finished,
    /// timed out, or was cancelled). Returns the owning session id when an
    /// entry was removed.
    pub async fn discard(&self, request_id: &str) -> Option<String> {
        let session_id = self.session_for_request(request_id).await?;
        self.inner.write().await.remove(&session_id)?;
        Some(session_id)
    }

    /// Watch the registered prompt and drop it once the tool stops waiting
    /// (timeout, cancel, process exit) without an answer. Cheap polling: the
    /// receiver side of the oneshot is owned by the tool task and is dropped
    /// when that task ends, which `Sender::is_closed` observes.
    pub fn spawn_abandon_watcher(&self, session_id: String, request_id: String) {
        let store = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                let entry = {
                    let map = store.inner.read().await;
                    match map.get(&session_id) {
                        Some(entry) if entry.request_id == request_id => Arc::clone(entry),
                        _ => return,
                    }
                };
                let abandoned = match entry.response_tx.lock().await.as_ref() {
                    Some(tx) => tx.is_closed(),
                    None => return,
                };
                if abandoned {
                    let mut map = store.inner.write().await;
                    if map
                        .get(&session_id)
                        .is_some_and(|entry| entry.request_id == request_id)
                    {
                        map.remove(&session_id);
                    }
                    return;
                }
            }
        });
    }

    /// Drop whatever prompt is pending for `session_id`.
    pub async fn discard_session(&self, session_id: &str) -> Option<PendingPromptInfo> {
        let entry = self.inner.write().await.remove(session_id)?;
        Some(PendingPromptInfo {
            request_id: entry.request_id.clone(),
            prompt: entry.prompt.clone(),
            is_password: entry.is_password,
            tool_call_id: entry.tool_call_id.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn resolve_delivers_once_and_removes_entry() {
        let store = PendingPromptStore::new();
        let (tx, rx) = oneshot::channel();
        store
            .register("s1", "r1".into(), "".into(), false, "tc".into(), tx)
            .await;
        assert_eq!(
            store.pending_prompt_for("s1").await.map(|p| p.request_id),
            Some("r1".to_string())
        );
        assert_eq!(
            store.resolve("r1", "hello".into()).await.as_deref(),
            Some("s1")
        );
        assert_eq!(rx.await.unwrap(), "hello");
        assert!(store.pending_prompt_for("s1").await.is_none());
        assert!(store.resolve("r1", "again".into()).await.is_none());
    }

    #[tokio::test]
    async fn discard_drops_sender_so_tool_unblocks() {
        let store = PendingPromptStore::new();
        let (tx, rx) = oneshot::channel::<String>();
        store
            .register("s1", "r1".into(), "".into(), false, "tc".into(), tx)
            .await;
        assert_eq!(store.discard("r1").await.as_deref(), Some("s1"));
        assert!(rx.await.is_err());
        assert!(store.pending_prompt_for("s1").await.is_none());
    }
}
