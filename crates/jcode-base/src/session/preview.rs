use serde::{Deserialize, Serialize};

use crate::message::{ContentBlock, Role};
use jcode_session_types::StoredMessage;

/// Maximum characters kept in a persisted message preview.
pub const MESSAGE_PREVIEW_MAX_CHARS: usize = 240;

/// Cheap, persisted summary of the last visible text message in a session.
///
/// Written next to the other lightweight metadata so session listings can
/// show a preview from the startup stub without parsing the transcript.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StoredMessagePreview {
    pub role: Role,
    pub text: String,
}

/// Strip `<system-reminder>…</system-reminder>` blocks so a preview never
/// shows injected context. An unterminated block is dropped to the end.
pub fn strip_system_reminders(text: &str) -> String {
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

fn truncate_chars(text: &str) -> String {
    let mut out: String = text.chars().take(MESSAGE_PREVIEW_MAX_CHARS).collect();
    if out.len() < text.len() {
        out.push('…');
    }
    out
}

/// Preview of the last message that has non-empty text after reminder
/// stripping. Text blocks only; tool calls and images are ignored.
pub fn last_message_preview(messages: &[StoredMessage]) -> Option<StoredMessagePreview> {
    messages.iter().rev().find_map(|message| {
        let text = strip_system_reminders(&message_text(message));
        if text.is_empty() {
            return None;
        }
        Some(StoredMessagePreview {
            role: message.role.clone(),
            text: truncate_chars(&text),
        })
    })
}
