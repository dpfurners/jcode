use super::{StdinInputRequest, Tool, ToolContext, ToolOutput};
use anyhow::Result;
use async_trait::async_trait;
use serde_json::{Value, json};
use std::time::Duration;

/// How long a question stays open before the tool gives up. Long enough for a
/// human to come back to the keyboard, short enough that an unattended session
/// does not hang a turn forever.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// Lets the model ask the user a question mid-turn and wait for the answer.
///
/// Models keep inventing this tool ("AskUserQuestion", "ask_question", ...)
/// and hitting `Unknown tool`, because the need is real: sometimes the next
/// step depends on a fact only the user has. The transport already exists —
/// `stdin_request`/`stdin_response` carry a prompt to every connected client
/// and route one answer back — so this tool is a thin bridge onto it rather
/// than a new protocol surface.
pub struct AskUserTool;

impl Default for AskUserTool {
    fn default() -> Self {
        Self::new()
    }
}

impl AskUserTool {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Tool for AskUserTool {
    fn name(&self) -> &str {
        "ask_user"
    }

    fn description(&self) -> &str {
        "Ask the user one question and wait for their typed answer. Use only when blocked on a fact or decision only the user has; prefer proceeding autonomously otherwise."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["question"],
            "properties": {
                "intent": super::intent_schema_property(),
                "question": {
                    "type": "string",
                    "description": "The question to show the user. Include the options inline when there are specific choices."
                },
                "is_password": {
                    "type": "boolean",
                    "description": "Mask the user's input (secrets). Default false."
                }
            }
        })
    }

    async fn execute(&self, input: Value, ctx: ToolContext) -> Result<ToolOutput> {
        let question = input
            .get("question")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|q| !q.is_empty())
            .ok_or_else(|| anyhow::anyhow!("ask_user requires a non-empty 'question'"))?;
        let is_password = input
            .get("is_password")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let Some(stdin_tx) = ctx.stdin_request_tx.clone() else {
            // Headless contexts (direct tool invocation, some subagents) have
            // no user to ask; failing with a clear reason lets the model make
            // its best autonomous choice instead of retrying.
            anyhow::bail!(
                "ask_user is unavailable in this session (no interactive client attached); decide autonomously and state the assumption"
            );
        };

        let (response_tx, response_rx) = tokio::sync::oneshot::channel();
        // The `stdin-{tool_call_id}-{n}` shape is what clients already parse to
        // attribute a request to its tool call; keep it.
        let request = StdinInputRequest {
            request_id: format!("stdin-{}-1", ctx.tool_call_id),
            prompt: question.to_string(),
            is_password,
            tool_call_id: ctx.tool_call_id.clone(),
            response_tx,
        };
        if stdin_tx.send(request).is_err() {
            anyhow::bail!(
                "ask_user could not reach a client; decide autonomously and state the assumption"
            );
        }

        match tokio::time::timeout(ANSWER_TIMEOUT, response_rx).await {
            Ok(Ok(answer)) => {
                let shown = answer.trim();
                let text = if is_password {
                    // Never echo a secret back into the transcript.
                    format!("User provided a masked answer ({} chars).", shown.len())
                } else if shown.is_empty() {
                    "User submitted an empty answer.".to_string()
                } else {
                    format!("User answered: {shown}")
                };
                Ok(ToolOutput::new(text).with_title(question.to_string()))
            }
            Ok(Err(_)) => anyhow::bail!(
                "the question was dismissed without an answer; decide autonomously and state the assumption"
            ),
            Err(_) => anyhow::bail!(
                "no answer within {} minutes; decide autonomously and state the assumption",
                ANSWER_TIMEOUT.as_secs() / 60
            ),
        }
    }
}
