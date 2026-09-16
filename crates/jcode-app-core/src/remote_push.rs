//! Interactive push notifications (`[notifications] remote`).
//!
//! Pushes short, private-safe summaries of interactive session events through
//! the `[safety]` notification channels (ntfy, email, chat channels) so a
//! phone can learn that a session needs input, failed, or finished a long
//! turn. Bodies never include the prompt or assistant text.
//!
//! ntfy receives a `Click` header with the deep link
//! `jcode://session?host=<hostname -s>&id=<session_id>`.

use std::sync::OnceLock;
use std::time::Duration;

use crate::config::config;
use crate::notifications::{NotificationDispatcher, Priority};

/// Error text limit in a failure push.
const ERROR_SNIPPET_CHARS: usize = 80;

static SERVER_NAME: OnceLock<String> = OnceLock::new();
static SHORT_HOSTNAME: OnceLock<String> = OnceLock::new();

/// Record the daemon's display name (e.g. "blazing") once at startup so
/// pushes can say "<session> on <server>".
pub fn set_server_name(name: &str) {
    let _ = SERVER_NAME.set(name.to_string());
}

/// The daemon's display name, or the short hostname when no server name was
/// registered (single-process CLI mode).
pub fn server_name() -> String {
    SERVER_NAME.get().cloned().unwrap_or_else(short_hostname)
}

/// `hostname -s`: the first label of the machine's hostname, cached.
pub fn short_hostname() -> String {
    SHORT_HOSTNAME
        .get_or_init(|| {
            let raw = std::env::var("HOSTNAME")
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .or_else(|| {
                    std::process::Command::new("uname")
                        .arg("-n")
                        .output()
                        .ok()
                        .filter(|o| o.status.success())
                        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                        .filter(|s| !s.is_empty())
                })
                .unwrap_or_else(|| "localhost".to_string());
            raw.split('.').next().unwrap_or(&raw).to_string()
        })
        .clone()
}

/// Deep link the phone app opens for a session on this machine.
pub fn session_deep_link(session_id: &str) -> String {
    format!(
        "jcode://session?host={}&id={}",
        short_hostname(),
        session_id
    )
}

/// What kind of interactive event to push.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemotePushEvent {
    NeedsInput,
    TurnFailed { error: String },
    TurnFinished { duration: Duration },
}

/// Format `(title, body, priority)` for an event. Pure; used by tests.
pub fn format_push(
    short_name: &str,
    server_name: &str,
    event: &RemotePushEvent,
) -> (String, String, Priority) {
    match event {
        RemotePushEvent::NeedsInput => (
            "jcode: input needed".to_string(),
            format!("{short_name} on {server_name} needs your input"),
            Priority::High,
        ),
        RemotePushEvent::TurnFailed { error } => {
            let snippet: String = error
                .lines()
                .next()
                .unwrap_or_default()
                .chars()
                .take(ERROR_SNIPPET_CHARS)
                .collect();
            (
                "jcode: turn failed".to_string(),
                format!("{short_name} on {server_name} failed: {snippet}"),
                Priority::High,
            )
        }
        RemotePushEvent::TurnFinished { duration } => (
            "jcode: turn finished".to_string(),
            format!(
                "{short_name} on {server_name} finished ({})",
                format_duration(*duration)
            ),
            Priority::Default,
        ),
    }
}

/// `3m 12s`, `45s`, `1h 2m 3s`.
pub fn format_duration(duration: Duration) -> String {
    let total = duration.as_secs();
    let hours = total / 3600;
    let minutes = (total % 3600) / 60;
    let seconds = total % 60;
    if hours > 0 {
        format!("{hours}h {minutes}m {seconds}s")
    } else if minutes > 0 {
        format!("{minutes}m {seconds}s")
    } else {
        format!("{seconds}s")
    }
}

/// Decide whether a completed turn should push, given the configured
/// threshold. Errors always push; ok turns push at or above the threshold.
pub fn turn_end_event(
    result: Result<(), &str>,
    duration: Duration,
    min_secs: u64,
) -> Option<RemotePushEvent> {
    match result {
        Err(error) => Some(RemotePushEvent::TurnFailed {
            error: error.to_string(),
        }),
        Ok(()) if duration.as_secs() >= min_secs => {
            Some(RemotePushEvent::TurnFinished { duration })
        }
        Ok(()) => None,
    }
}

/// Push a "needs your input" notification for a session. No-op unless
/// `[notifications] remote = true`.
pub fn notify_needs_input(session_id: &str, short_name: &str) {
    if !config().notifications.remote {
        return;
    }
    dispatch(session_id, short_name, &RemotePushEvent::NeedsInput);
}

/// Push a turn-end notification (error always, ok only when the turn ran at
/// least `remote_turn_min_secs`). No-op unless `[notifications] remote = true`.
pub fn notify_turn_end(
    session_id: &str,
    short_name: &str,
    result: Result<(), &str>,
    duration: Duration,
) {
    let notifications = &config().notifications;
    if !notifications.remote {
        return;
    }
    if let Some(event) = turn_end_event(result, duration, notifications.remote_turn_min_secs) {
        dispatch(session_id, short_name, &event);
    }
}

fn dispatch(session_id: &str, short_name: &str, event: &RemotePushEvent) {
    let (title, body, priority) = format_push(short_name, &server_name(), event);
    let click_url = session_deep_link(session_id);
    NotificationDispatcher::new().send_interactive(&title, &body, priority, Some(&click_url));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bodies_never_include_prompt_or_assistant_text() {
        let (title, body, priority) = format_push("otter", "blazing", &RemotePushEvent::NeedsInput);
        assert_eq!(title, "jcode: input needed");
        assert_eq!(body, "otter on blazing needs your input");
        assert_eq!(priority, Priority::High);

        let long_error = format!("{}\nsecond line", "e".repeat(200));
        let (_, body, priority) = format_push(
            "otter",
            "blazing",
            &RemotePushEvent::TurnFailed { error: long_error },
        );
        assert_eq!(priority, Priority::High);
        assert_eq!(body, format!("otter on blazing failed: {}", "e".repeat(80)));

        let (_, body, priority) = format_push(
            "otter",
            "blazing",
            &RemotePushEvent::TurnFinished {
                duration: Duration::from_secs(192),
            },
        );
        assert_eq!(priority, Priority::Default);
        assert_eq!(body, "otter on blazing finished (3m 12s)");
    }

    #[test]
    fn duration_formatting() {
        assert_eq!(format_duration(Duration::from_secs(5)), "5s");
        assert_eq!(format_duration(Duration::from_secs(65)), "1m 5s");
        assert_eq!(format_duration(Duration::from_secs(3723)), "1h 2m 3s");
    }

    #[test]
    fn threshold_gate() {
        assert_eq!(turn_end_event(Ok(()), Duration::from_secs(59), 60), None);
        assert_eq!(
            turn_end_event(Ok(()), Duration::from_secs(60), 60),
            Some(RemotePushEvent::TurnFinished {
                duration: Duration::from_secs(60)
            })
        );
        assert_eq!(
            turn_end_event(Err("boom"), Duration::from_secs(0), 60),
            Some(RemotePushEvent::TurnFailed {
                error: "boom".to_string()
            })
        );
    }

    #[test]
    fn deep_link_uses_short_hostname() {
        let link = session_deep_link("session_x_1");
        let host = short_hostname();
        assert!(!host.contains('.'));
        assert_eq!(link, format!("jcode://session?host={host}&id=session_x_1"));
    }
}

#[cfg(test)]
mod gate_tests {
    use super::*;

    /// With `remote = false` (the default) no notification is dispatched even
    /// when every ntfy setting points at a reachable server: the local HTTP
    /// listener must never see a request.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn remote_disabled_dispatches_nothing() {
        let _guard = crate::storage::lock_test_env();
        let prev_home = std::env::var_os("JCODE_HOME");
        let home = tempfile::TempDir::new().expect("temp home");
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.set_nonblocking(true).expect("nonblocking");
        let port = listener.local_addr().expect("addr").port();
        std::fs::write(
            home.path().join("config.toml"),
            format!(
                "[notifications]\nremote = false\nremote_turn_min_secs = 0\n\n[safety]\nntfy_topic = \"t\"\nntfy_server = \"http://127.0.0.1:{port}\"\n"
            ),
        )
        .expect("write config");
        crate::env::set_var("JCODE_HOME", home.path());
        crate::config::Config::invalidate_cache();
        assert!(!config().notifications.remote);
        assert_eq!(config().safety.ntfy_topic.as_deref(), Some("t"));

        notify_needs_input("session_otter_1", "otter");
        notify_turn_end(
            "session_otter_1",
            "otter",
            Err("boom"),
            Duration::from_secs(0),
        );
        notify_turn_end("session_otter_1", "otter", Ok(()), Duration::from_secs(600));
        tokio::time::sleep(Duration::from_millis(300)).await;

        match listener.accept() {
            Ok(_) => panic!("remote=false must not send any notification"),
            Err(error) => assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock),
        }

        if let Some(previous) = prev_home {
            crate::env::set_var("JCODE_HOME", previous);
        } else {
            crate::env::remove_var("JCODE_HOME");
        }
        crate::config::Config::invalidate_cache();
    }
}
