#!/usr/bin/env python3
"""Deterministic mock jcode gateway for end-to-end iOS app testing.

Speaks the exact wire protocol from `crates/jcode-base/src/gateway.rs` on a
single TCP port, peeking the request line to route like the real gateway:
  - GET  /health   -> {status, version, gateway}
  - POST /pair     -> {token, server_name, server_version}
  - GET  /ws       -> WebSocket upgrade; newline-delimited JSON event protocol

It does NOT call an LLM. A `message` request triggers a scripted, deterministic
stream (reasoning, text deltas, a tool-call lifecycle, tokens, done) so the app
can be exercised and visually validated without network or provider cost. This
is the iOS equivalent of the removed Rust simulator: one source of honest,
repeatable behavior to develop the client against.

Self-contained: no third-party deps. Minimal hand-rolled WebSocket framing.

Run:  python3 mock_gateway.py [--port 7643] [--code 123456]
"""

import argparse
import asyncio
import base64
import hashlib
import json
import struct
import sys

import os
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SERVER_VERSION = "mock-0.32.0"
SERVER_NAME = "mock-jcode"
SERVER_ICON = "🧪"
SKILLS = ["grill-me", "caveman", "humanizer", "optimization"]
DEFAULT_MODELS = [
    "claude-api:claude-fable-5",
    "claude-api:claude-sonnet-4",
    "openai:gpt-5",
    "gemini:gemini-2.5-pro",
]


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


class GatewayState:
    def __init__(self, code, token, name=SERVER_NAME, icon=SERVER_ICON):
        self.code = code
        self.token = token
        self.name = name
        self.icon = icon
        self.session_id = "mock-session-0001"
        self.title = "Mock session"
        self.model = DEFAULT_MODELS[0]
        self.messages = []
        self.token_input = 0
        self.token_output = 0
        self.reasoning_effort = "high"
        self.push_demo = False
        # Board tier (docs/PHONE-WIRE.md `list_sessions`). Keyed by id; the
        # first entry is the session `subscribe` without a target attaches to.
        now = time.time()
        self.board = {
            self.session_id: {
                "id": self.session_id, "short_name": "mock", "title": self.title,
                "working_dir": "/Users/me/dev/jcode",
                "created_at": iso(now - 3600), "updated_at": iso(now - 60),
                "last_active_at": iso(now - 60),
                "model": self.model, "provider": "claude",
                "phase": "idle", "reason": None, "current_tool": None,
                "turn_started_at": None, "queued": 0, "pending_prompt": None,
                "preview": {"kind": "assistant", "text": "Done. Output above."},
                "client_count": 0, "is_live": True, "parent_id": None, "swarm_role": None,
            },
            "mock-session-0002": {
                "id": "mock-session-0002", "short_name": "fox", "title": "Fix the queue bar",
                "working_dir": "/Users/me/dev/jed",
                "created_at": iso(now - 7200), "updated_at": iso(now - 5),
                "last_active_at": iso(now - 5),
                "model": "claude-api:claude-opus-4", "provider": "claude",
                "phase": "needs_you", "reason": "waiting for input", "current_tool": "ask_user",
                "turn_started_at": iso(now - 95), "queued": 1,
                "pending_prompt": {"request_id": "req-fox-1", "prompt": "Which DB should I use? ",
                                   "is_password": False, "tool_call_id": "tool-ask-1"},
                "preview": {"kind": "prompt", "text": "Which DB should I use?"},
                "client_count": 1, "is_live": True, "parent_id": None, "swarm_role": None,
            },
            "mock-session-0003": {
                "id": "mock-session-0003", "short_name": "owl", "title": None,
                "working_dir": "/Users/me/dev/jcode",
                "created_at": iso(now - 900), "updated_at": iso(now - 2),
                "last_active_at": iso(now - 2),
                "model": self.model, "provider": "claude",
                "phase": "running", "reason": None, "current_tool": "bash",
                "turn_started_at": iso(now - 42), "queued": 0, "pending_prompt": None,
                "preview": {"kind": "streaming", "text": "Running the test suite now, this may take"},
                "client_count": 0, "is_live": True, "parent_id": None, "swarm_role": None,
            },
            "mock-session-0004": {
                "id": "mock-session-0004", "short_name": "elk", "title": "Migrate to SwiftData",
                "working_dir": "/Users/me/dev/jcode-mobile",
                "created_at": iso(now - 86400), "updated_at": iso(now - 3000),
                "last_active_at": iso(now - 3000),
                "model": "openai:gpt-5", "provider": "openai",
                "phase": "failed", "reason": "rate limited", "current_tool": None,
                "turn_started_at": None, "queued": 0, "pending_prompt": None,
                "preview": {"kind": "user", "text": "please migrate the store"},
                "client_count": 0, "is_live": False, "parent_id": None, "swarm_role": None,
            },
        }
        self.recent_projects = [
            {"path": "/Users/me/dev/jed", "last_used_at": iso(now - 5), "session_count": 41},
            {"path": "/Users/me/dev/jcode", "last_used_at": iso(now - 2), "session_count": 12},
            {"path": "/Users/me/dev/jcode-mobile", "last_used_at": iso(now - 3000), "session_count": 3},
        ]
        # Fake filesystem for search_files.
        self.files = [
            ("Sources/JCodeKit/Wire.swift", False),
            ("Sources/JCodeKit/SessionReducer.swift", False),
            ("Sources/JCodeMobile/Views/Composer.swift", False),
            ("Sources/JCodeMobile/Views/ChatView.swift", False),
            ("TestHarness/mock_gateway.py", False),
            ("Sources", True),
            ("TestHarness", True),
        ]
        self.dirs = ["/Users/me/dev/jed", "/Users/me/dev/jcode", "/Users/me/dev/jcode-mobile",
                     "/Users/me/dev/scratch", "/Users/me/Documents", "/tmp"]

    def sessions_payload(self, req_id, limit=100, include_workers=False):
        rows = sorted(self.board.values(), key=lambda r: r["updated_at"], reverse=True)
        if not include_workers:
            rows = [r for r in rows if r.get("parent_id") is None]
        return {
            "type": "sessions", "id": req_id,
            "server_name": self.name, "server_icon": self.icon,
            "server_version": SERVER_VERSION,
            "sessions": rows[:limit],
            "recent_projects": self.recent_projects,
        }


def scenario_messages(name):
    """Pre-seeded transcripts for the layout matrix. Each is a deterministic
    content state so UI efficiency can be measured across the real range."""
    bash_tool = {
        "id": "t1", "name": "bash",
        "input": '{"command": "echo hello"}',
        "output": "hello\n", "error": None,
    }
    if name == "empty":
        return []
    if name == "short":
        return [
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "Hello! How can I help?"},
        ]
    if name == "tool":
        return [
            {"role": "user", "content": "run echo hello"},
            {"role": "assistant", "content": "Done. Output above.", "tool_data": bash_tool},
        ]
    if name == "long":
        turns = []
        for i in range(6):
            turns.append({"role": "user", "content": f"Question number {i + 1} about the codebase?"})
            turns.append({
                "role": "assistant",
                "content": (
                    f"Answer {i + 1}: here is a reasonably detailed paragraph that "
                    "wraps across multiple lines to simulate a real assistant reply "
                    "with enough text to fill vertical space and exercise scrolling."
                ),
                "tool_data": bash_tool if i % 2 == 0 else None,
            })
        return turns
    if name == "code":
        return [
            {"role": "user", "content": "show me a python snippet"},
            {"role": "assistant", "content": (
                "Sure:\n\n```python\ndef fib(n):\n    a, b = 0, 1\n    for _ in range(n):\n"
                "        a, b = b, a + b\n    return a\n```\n\nThat is iterative and O(n)."
            )},
        ]
    return []


# ---------------------------------------------------------------------------
# WebSocket framing (server side)
# ---------------------------------------------------------------------------

def ws_accept_key(key: str) -> str:
    digest = hashlib.sha1((key + WS_GUID).encode()).digest()
    return base64.b64encode(digest).decode()


def encode_text_frame(text: str) -> bytes:
    payload = text.encode("utf-8")
    header = bytearray([0x81])  # FIN + text opcode
    length = len(payload)
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header += struct.pack(">H", length)
    else:
        header.append(127)
        header += struct.pack(">Q", length)
    return bytes(header) + payload


def encode_control_frame(opcode: int, payload: bytes = b"") -> bytes:
    header = bytearray([0x80 | opcode, len(payload)])
    return bytes(header) + payload


async def read_frame(reader: asyncio.StreamReader):
    """Returns (opcode, payload_bytes) or None on EOF/close."""
    try:
        b = await reader.readexactly(2)
    except asyncio.IncompleteReadError:
        return None
    opcode = b[0] & 0x0F
    masked = (b[1] & 0x80) != 0
    length = b[1] & 0x7F
    if length == 126:
        ext = await reader.readexactly(2)
        length = struct.unpack(">H", ext)[0]
    elif length == 127:
        ext = await reader.readexactly(8)
        length = struct.unpack(">Q", ext)[0]
    mask = await reader.readexactly(4) if masked else b"\x00\x00\x00\x00"
    data = await reader.readexactly(length) if length else b""
    if masked:
        data = bytes(data[i] ^ mask[i % 4] for i in range(len(data)))
    return opcode, data


class WSConn:
    """Minimal server-side WebSocket connection wrapper."""

    def __init__(self, writer: asyncio.StreamWriter):
        self.writer = writer
        self._lock = asyncio.Lock()

    async def send(self, text: str):
        async with self._lock:
            self.writer.write(encode_text_frame(text))
            await self.writer.drain()

    async def pong(self, payload: bytes):
        async with self._lock:
            self.writer.write(encode_control_frame(0xA, payload))
            await self.writer.drain()

    async def close(self):
        try:
            async with self._lock:
                self.writer.write(encode_control_frame(0x8))
                await self.writer.drain()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Protocol behavior
# ---------------------------------------------------------------------------

def jline(obj):
    return json.dumps(obj)


def chunk_text(text, size):
    for i in range(0, len(text), size):
        yield text[i : i + size]


async def send_event(ws: WSConn, obj):
    await ws.send(jline(obj))


async def stream_response(ws, state, user_text, req_id):
    await send_event(ws, {"type": "ack", "id": req_id})

    for chunk in ["Looking at ", "the request", "..."]:
        await send_event(ws, {"type": "reasoning_delta", "text": chunk})
        await asyncio.sleep(0.05)
    await send_event(ws, {"type": "reasoning_done", "duration_secs": 0.4})

    intro = f"You said: {user_text}\n\nRunning a quick tool to demonstrate.\n\n"
    for ch in chunk_text(intro, 6):
        await send_event(ws, {"type": "text_delta", "text": ch})
        await asyncio.sleep(0.02)

    tool_id = f"tool-{req_id}"
    await send_event(ws, {"type": "tool_start", "id": tool_id, "name": "bash"})
    for piece in ['{"command":', ' "echo ', 'hello"}']:
        await send_event(ws, {"type": "tool_input", "delta": piece})
        await asyncio.sleep(0.03)
    await send_event(ws, {"type": "tool_exec", "id": tool_id, "name": "bash"})
    await asyncio.sleep(0.2)
    await send_event(ws, {
        "type": "tool_done", "id": tool_id, "name": "bash",
        "output": "hello\n", "error": None,
    })

    answer = (
        "Done. Here is a code block:\n\n"
        "```python\nprint('hello from mock gateway')\n```\n\n"
        "And a **bold** word plus `inline code`."
    )
    for ch in chunk_text(answer, 8):
        await send_event(ws, {"type": "text_delta", "text": ch})
        await asyncio.sleep(0.02)

    await send_event(ws, {"type": "message_end"})

    state.token_input += 120 + len(user_text)
    state.token_output += 240
    await send_event(ws, {"type": "tokens", "input": state.token_input, "output": state.token_output})

    state.messages.append({"role": "user", "content": user_text})
    state.messages.append({
        "role": "assistant", "content": answer,
        "tool_data": {
            "id": tool_id, "name": "bash",
            "input": '{"command": "echo hello"}',
            "output": "hello\n", "error": None,
        },
    })

    await send_event(ws, {"type": "done", "id": req_id})


def history_payload(state, req_id):
    return {
        "type": "history",
        "id": req_id,
        "session_id": state.session_id,
        "messages": state.messages,
        "provider_name": "anthropic-api",
        "provider_model": state.model,
        "available_models": DEFAULT_MODELS,
        "total_tokens": [state.token_input, state.token_output],
        "all_sessions": [state.session_id, "mock-session-0002"],
        "server_version": SERVER_VERSION,
        "display_title": state.title,
        "reasoning_effort": state.reasoning_effort,
        "skills": SKILLS,
    }


def fuzzy_match(query, path):
    """Subsequence match, case-insensitive (mirrors the server's fuzzy mode)."""
    q = query.lower()
    it = iter(path.lower())
    return all(ch in it for ch in q)


def file_matches_payload(state, req_id, msg):
    query = msg.get("query", "")
    limit = int(msg.get("limit") or 30)
    dirs_only = bool(msg.get("dirs_only", False))
    if query.startswith("/"):
        hits = [{"path": d, "is_dir": True} for d in state.dirs if d.startswith(query)]
    else:
        hits = [{"path": p, "is_dir": d} for p, d in state.files
                if (not dirs_only or d) and fuzzy_match(query, p)]
    return {"type": "file_matches", "id": req_id, "query": query, "matches": hits[:limit]}


class ConnState:
    """Per-connection facts: which session it is attached to and whether a
    pending prompt still has to be replayed after `history`."""

    def __init__(self, session_id):
        self.session_id = session_id
        self.replay_prompt = None


async def handle_request(ws, state, raw, conn=None):
    conn = conn or ConnState(state.session_id)
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        return
    req_type = msg.get("type")
    req_id = int(msg.get("id", 0))
    print(f"[ws] <- {req_type} id={req_id}", file=sys.stderr)

    if req_type == "subscribe":
        target = msg.get("target_session_id")
        working_dir = msg.get("working_dir")
        if target and target not in state.board:
            await send_event(ws, {"type": "error", "id": req_id, "message": f"unknown session {target}"})
            return
        if target:
            conn.session_id = target
        elif working_dir:
            # New session in a project: the real daemon rejects a missing
            # directory; the mock only knows its fake tree.
            if working_dir not in state.dirs:
                await send_event(ws, {"type": "error", "id": req_id,
                                      "message": f"working_dir does not exist: {working_dir}"})
                return
            new_id = f"mock-session-{len(state.board) + 1:04d}"
            state.board[new_id] = {
                **state.board[state.session_id], "id": new_id, "short_name": "new",
                "title": None, "working_dir": working_dir, "phase": "idle",
                "preview": None, "created_at": iso(time.time()), "updated_at": iso(time.time()),
                "is_live": True, "client_count": 1,
            }
            conn.session_id = new_id
        else:
            conn.session_id = state.session_id
        row = state.board[conn.session_id]
        await send_event(ws, {"type": "ack", "id": req_id})
        await send_event(ws, {"type": "session", "session_id": conn.session_id})
        await send_event(ws, {
            "type": "state", "id": req_id, "session_id": conn.session_id,
            "message_count": len(state.messages), "is_processing": row["phase"] in ("running", "needs_you"),
        })
        conn.replay_prompt = row.get("pending_prompt")
    elif req_type == "get_history":
        payload = history_payload(state, req_id)
        payload["session_id"] = conn.session_id
        row = state.board.get(conn.session_id, {})
        if row.get("title"):
            payload["display_title"] = row["title"]
        if conn.session_id != state.session_id:
            payload["messages"] = scenario_messages("short") if conn.session_id != "mock-session-0002" else [
                {"role": "user", "content": "Set up the database layer"},
                {"role": "assistant", "content": "I need to know which database you prefer before continuing.",
                 "tool_data": {"id": "tool-ask-1", "name": "ask_user",
                               "input": '{"question": "Which DB should I use?"}', "output": None, "error": None}},
            ]
        await send_event(ws, payload)
        # Pending prompts survive reconnects: replay after history.
        if conn.replay_prompt:
            await send_event(ws, {"type": "stdin_request", **conn.replay_prompt})
            conn.replay_prompt = None
    elif req_type == "list_sessions":
        await send_event(ws, state.sessions_payload(
            req_id, int(msg.get("limit") or 100), bool(msg.get("include_workers", False))))
    elif req_type == "close_session":
        sid = msg.get("session_id")
        if sid not in state.board:
            await send_event(ws, {"type": "error", "id": req_id, "message": f"unknown session {sid}"})
            return
        delete = bool(msg.get("delete", False))
        if delete:
            del state.board[sid]
        else:
            row = state.board[sid]
            row.update({"phase": "idle", "current_tool": None, "turn_started_at": None,
                        "queued": 0, "pending_prompt": None, "is_live": False, "client_count": 0})
        await send_event(ws, {"type": "session_closed", "id": req_id, "session_id": sid, "deleted": delete})
    elif req_type == "search_files":
        await send_event(ws, file_matches_payload(state, req_id, msg))
    elif req_type == "stdin_response":
        rid = msg.get("request_id")
        row = state.board.get(conn.session_id, {})
        pp = row.get("pending_prompt")
        if pp and pp["request_id"] == rid:
            row.update({"pending_prompt": None, "phase": "running", "current_tool": "bash",
                        "preview": {"kind": "streaming", "text": f"Using {msg.get('input', '')}"}})
            await send_event(ws, {"type": "ack", "id": req_id})
            await send_event(ws, {"type": "stdin_resolved", "request_id": rid})
            await send_event(ws, {"type": "text_delta", "text": f"Using {msg.get('input', '')}. "})
            await send_event(ws, {"type": "message_end"})
            row.update({"phase": "idle", "current_tool": None, "turn_started_at": None})
            await send_event(ws, {"type": "done", "id": req_id})
        else:
            await send_event(ws, {"type": "error", "id": req_id, "message": f"no pending request {rid}"})
    elif req_type == "message":
        images = msg.get("images") or []
        content = msg.get("content", "")
        if images:
            content += f" [+{len(images)} image(s): {', '.join(i[0] for i in images)}]"
        if msg.get("active_skill"):
            content += f" [skill={msg['active_skill']}]"
        await stream_response(ws, state, content, req_id)
    elif req_type == "soft_interrupt":
        await send_event(ws, {"type": "ack", "id": req_id})
        # Mirror the real server: confirm the queued message was injected
        # before streaming the (echoed) response it participates in.
        await send_event(ws, {
            "type": "soft_interrupt_injected",
            "content": msg.get("content", ""),
            "display_role": "user",
            "point": "immediate",
            "tools_skipped": 0,
        })
        await stream_response(ws, state, msg.get("content", ""), req_id)
    elif req_type == "cancel":
        await send_event(ws, {"type": "interrupted"})
        await send_event(ws, {"type": "done", "id": req_id})
    elif req_type == "ping":
        await send_event(ws, {"type": "pong", "id": req_id})
    elif req_type == "set_model":
        state.model = msg.get("model", state.model)
        await send_event(ws, {"type": "model_changed", "id": req_id, "model": state.model, "error": None})
        await send_event(ws, {"type": "available_models_updated", "available_models": DEFAULT_MODELS, "provider_model": state.model})
    elif req_type == "set_reasoning_effort":
        state.reasoning_effort = msg.get("effort", state.reasoning_effort)
        await send_event(ws, {"type": "reasoning_effort_changed", "id": req_id, "effort": state.reasoning_effort, "error": None})
    elif req_type == "compact":
        await send_event(ws, {"type": "compact_result", "id": req_id, "message": "Compacted context (2048 tokens saved)", "success": True})
    elif req_type == "rename_session":
        state.title = msg.get("title") or "Untitled"
        await send_event(ws, {"type": "session_renamed", "session_id": state.session_id, "display_title": state.title})
    elif req_type == "resume_session":
        sid = msg.get("session_id", state.session_id)
        state.session_id = sid
        state.messages = []
        await send_event(ws, {"type": "session", "session_id": sid})
        await send_event(ws, history_payload(state, req_id))
    elif req_type == "clear":
        state.messages = []
        await send_event(ws, history_payload(state, req_id))
    elif req_type == "cancel_soft_interrupts":
        await send_event(ws, {"type": "ack", "id": req_id})
    elif req_type == "_notify":
        # Test-only: synthesize a push notification + a compaction notice.
        await send_event(ws, {"type": "notification", "from_name": "swarm", "message": "build finished"})
        await send_event(ws, {"type": "compaction", "trigger": "manual", "tokens_saved": 4096})
    elif req_type == "_prompt":
        # Test-only: raise a stdin_request on the attached session so the
        # inline prompt card can be exercised on demand.
        prompt = {"request_id": f"req-{req_id}", "prompt": msg.get("prompt", "Password: "),
                  "is_password": bool(msg.get("is_password", False)), "tool_call_id": "tool-x"}
        state.board[conn.session_id].update({"pending_prompt": prompt, "phase": "needs_you",
                                             "current_tool": "bash"})
        await send_event(ws, {"type": "stdin_request", **prompt})
    else:
        print(f"[ws] (ignored unknown request {req_type})", file=sys.stderr)


# ---------------------------------------------------------------------------
# HTTP + routing
# ---------------------------------------------------------------------------

def http_response(status_line, body):
    body_bytes = body.encode()
    head = (
        f"HTTP/1.1 {status_line}\r\n"
        "Content-Type: application/json\r\n"
        f"Content-Length: {len(body_bytes)}\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "\r\n"
    )
    return head.encode() + body_bytes


async def read_http_request(reader):
    """Reads headers (and body per Content-Length). Returns (method, path, headers, body)."""
    header_data = b""
    while b"\r\n\r\n" not in header_data:
        chunk = await reader.read(4096)
        if not chunk:
            break
        header_data += chunk
        if len(header_data) > 65536:
            break
    if b"\r\n\r\n" not in header_data:
        return None
    head, _, rest = header_data.partition(b"\r\n\r\n")
    lines = head.decode("latin1").split("\r\n")
    request_line = lines[0]
    parts = request_line.split()
    method, path = (parts[0], parts[1]) if len(parts) >= 2 else ("", "")
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    body = rest
    content_length = int(headers.get("content-length", "0") or "0")
    while len(body) < content_length:
        chunk = await reader.read(content_length - len(body))
        if not chunk:
            break
        body += chunk
    return method, path, headers, body


async def handle_connection(reader, writer, state):
    parsed = await read_http_request(reader)
    if parsed is None:
        writer.close()
        return
    method, path, headers, body = parsed
    path_base = path.split("?")[0]
    print(f"[http] {method} {path_base}", file=sys.stderr)

    if headers.get("upgrade", "").lower() == "websocket" and path_base == "/ws":
        await serve_websocket(reader, writer, headers, state)
        return

    if method == "GET" and path_base == "/health":
        body_str = jline({"status": "ok", "version": SERVER_VERSION, "gateway": True})
        writer.write(http_response("200 OK", body_str))
    elif method == "OPTIONS":
        writer.write(
            b"HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\n"
            b"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            b"Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
            b"Content-Length: 0\r\nConnection: close\r\n\r\n"
        )
    elif method == "POST" and path_base == "/pair":
        try:
            payload = json.loads(body.decode() or "{}")
        except Exception:
            payload = {}
        if payload.get("code", "") == state.code:
            resp = jline({"token": state.token, "server_name": state.name, "server_version": SERVER_VERSION})
            writer.write(http_response("200 OK", resp))
        else:
            resp = jline({"error": "Invalid or expired pairing code"})
            writer.write(http_response("401 Unauthorized", resp))
    else:
        writer.write(http_response("404 Not Found", jline({"error": "Not found"})))

    try:
        await writer.drain()
    except Exception:
        pass
    writer.close()


async def serve_websocket(reader, writer, headers, state):
    key = headers.get("sec-websocket-key")
    auth = headers.get("authorization", "")
    if not key:
        writer.close()
        return
    accept = ws_accept_key(key)
    handshake = (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n"
        "\r\n"
    )
    writer.write(handshake.encode())
    await writer.drain()
    ws = WSConn(writer)
    ok = auth == f"Bearer {state.token}"
    print(f"[ws] client connected (auth_ok={ok})", file=sys.stderr)

    keepalive = asyncio.create_task(keepalive_loop(ws))
    push_demo = None
    if getattr(state, "push_demo", False):
        push_demo = asyncio.create_task(push_demo_loop(ws))
    conn = ConnState(state.session_id)
    try:
        buffered = ""
        while True:
            frame = await read_frame(reader)
            if frame is None:
                break
            opcode, data = frame
            if opcode == 0x8:  # close
                break
            if opcode == 0x9:  # ping
                await ws.pong(data)
                continue
            if opcode in (0x1, 0x2):
                buffered += data.decode("utf-8", errors="replace")
                while "\n" in buffered:
                    line, buffered = buffered.split("\n", 1)
                    line = line.strip()
                    if line:
                        await handle_request(ws, state, line, conn)
                if buffered.strip():
                    await handle_request(ws, state, buffered.strip(), conn)
                    buffered = ""
    except (asyncio.IncompleteReadError, ConnectionResetError):
        pass
    finally:
        keepalive.cancel()
        if push_demo:
            push_demo.cancel()
        await ws.close()
        writer.close()
        print("[ws] client disconnected", file=sys.stderr)


async def push_demo_loop(ws):
    """Spontaneously push out-of-band notices to validate the toast UI."""
    try:
        await asyncio.sleep(2.5)
        await send_event(ws, {"type": "notification", "from_name": "swarm", "message": "build finished"})
        await asyncio.sleep(1.5)
        await send_event(ws, {"type": "compaction", "trigger": "manual", "tokens_saved": 4096})
    except asyncio.CancelledError:
        pass
    except Exception:
        pass


async def keepalive_loop(ws):
    try:
        while True:
            await asyncio.sleep(20)
            async with ws._lock:
                ws.writer.write(encode_control_frame(0x9))  # ping
                await ws.writer.drain()
    except asyncio.CancelledError:
        pass
    except Exception:
        pass


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=7643)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--code", default="123456")
    parser.add_argument("--token", default="mocktoken0123456789abcdef")
    parser.add_argument("--push-demo", action="store_true",
                        help="spontaneously push notification + compaction notices after connect")
    parser.add_argument("--scenario", default="",
                        help="pre-seed transcript: empty|short|tool|long|code")
    parser.add_argument("--name", default=SERVER_NAME, help="server_name (board chip)")
    parser.add_argument("--icon", default=SERVER_ICON, help="server_icon (board chip)")
    args = parser.parse_args()

    state = GatewayState(args.code, args.token, name=args.name, icon=args.icon)
    state.push_demo = args.push_demo
    if args.scenario:
        state.messages = scenario_messages(args.scenario)

    server = await asyncio.start_server(
        lambda r, w: handle_connection(r, w, state),
        args.host,
        args.port,
    )
    print(
        f"mock gateway: http+ws on {args.host}:{args.port} "
        f"(code={args.code}, token={args.token})",
        file=sys.stderr,
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
