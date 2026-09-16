# iOS E2E Test Harness

A deterministic, no-LLM harness for developing and validating the jcode iOS
client (`JCodeMobile`) end-to-end. It replaces the role of the old Rust
simulator: one source of honest, repeatable server behavior the client can be
built against on this machine, without a device, network, or provider cost.

## Pieces

- **`mock_gateway.py`** - a self-contained (stdlib-only) mock of the jcode
  server gateway. Speaks the exact wire protocol from
  `crates/jcode-base/src/gateway.rs` on one TCP port:
  - `GET /health` -> status/version
  - `POST /pair` -> token exchange (code `123456` by default)
  - `GET /ws` -> WebSocket upgrade carrying the newline-delimited JSON protocol
  A `message` request triggers a scripted assistant turn (reasoning, text
  deltas, a `bash` tool-call lifecycle, tokens, done). `--push-demo` also pushes
  an out-of-band notification + compaction notice after connect.

- **`protocol_smoke_test.py`** - a stdlib WebSocket/HTTP client that drives the
  mock and asserts the full happy-path event sequence (pair, subscribe,
  history, message stream, set_model). Run it against either the mock or a real
  `jcode` gateway.

- **`run_e2e.sh`** - the one-command pipeline: `swift test` -> build app ->
  start two mocks (`home-mini` :7643, `work-mini` :7644) -> smoke test ->
  boot simulator -> seed three credentials (the third points at a closed
  port so the board's "unreachable" header renders) -> launch -> screenshot
  the board -> deep-link into the needs_you session -> screenshot the chat.

- **Drivers** (each takes the simulator device name/UDID first):
  - `seed_credential.sh <device> <host> <port> <token> <server_name>` appends
    a paired server to the app container's credential fallback file.
  - `attach.sh <device> <session_id> [host]` opens
    `jcode://session?host=<host>&id=<session_id>` (host defaults to
    `127.0.0.1`, matched against the seeded server's literal host).
  - `answer_prompt.sh <device> <request_id> <text>` answers the pending
    prompt via `jcode://debug/answer?request_id=…&text=…` (DEBUG only), the
    same `stdin_response` path as the prompt card's Send. An empty
    `request_id` skips the id check.
  - `type_composer.sh <device> <text>` sets the composer draft via
    `jcode://debug/compose?text=…` (DEBUG only) so the completion popup
    computes: `/c` opens the slash list, `@comp` runs one `search_files`.
  - `debug_url.sh <device> <url>` delivers any `jcode://` URL to a DEBUG
    build without SpringBoard's "Open in jcode?" sheet: it appends to
    `<container>/tmp/jcode-debug-url`, which the app polls every 250 ms and
    routes through the same handler as `onOpenURL`. Release builds do not
    compile the poller. `JCODE_USE_OPENURL=1 attach.sh …` uses `simctl
    openurl` instead (interactive).
  - `read_sync_dump.sh <device>` prints `Documents/sync-dump.json` (see
    "Sync dump" below).

## Sync dump (DEBUG only)

`scripts/phone-sync-check.sh` in Jed diffs what the phone shows against Jed
and the daemon. DEBUG builds launched with the env var `JCODE_SYNC_DUMP=1`
(`SIMCTL_CHILD_JCODE_SYNC_DUMP=1 xcrun simctl launch <device>
com.jcode.mobile`) write `Documents/sync-dump.json` once on launch and then
after every board, reducer or composer change, coalesced to at most 4 writes
per second and written atomically (temp + rename). `SyncDumpWriter` and the
env check are compiled out of release builds; the encoding itself is
`JCodeKit.SyncDump` (unit tested). Read it with `read_sync_dump.sh <device>`.

```
{ "board": [ { "server": "<serverName>", "host": "<host>", "reachable": true,
               "sessions": [ ...the `sessions` rows from the wire, snake_case keys unchanged... ] } ],
  "attached": null | { "session_id": "…", "title": "…"|null, "model": "…"|null,
               "transcript": [ { "role": "user|assistant|system", "text": "…", "reasoning": "…",
                                 "streaming": false,
                                 "tool_calls": [ { "name": "bash",
                                                   "status": "streaming_input|running|succeeded|failed",
                                                   "has_input": true, "has_output": true } ] } ],
               "pending_prompt": null | { "request_id": "…", "prompt": "…", "is_password": false },
               "queued": [ "text", … ] },
  "completion": { "kind": "slash|file|none", "rows": [ "name-without-slash" | "relative/path" … ] } }
```

- `board[]` is one entry per paired server in the saved order; `sessions`
  are the decoded `SessionSummary` rows re-encoded with the wire's keys
  (absent optionals omitted, as the server omits them).
- `attached` is the reducer state the chat renders (never a second
  rendering); `queued` is the soft-interrupt texts not yet injected.
- `completion.rows` for `slash` are the popup's names without the `/`, in
  popup order; for `file` the relative paths exactly as a tap inserts them
  (without the `@`).

## Usage

```bash
# Full pipeline, screenshot lands in $TMPDIR/jcode-ios-e2e/chat.png
./TestHarness/run_e2e.sh

# Also exercise the out-of-band notice toasts
./TestHarness/run_e2e.sh --push-demo

# Just the protocol assertions against a running gateway (mock or real)
python3 TestHarness/mock_gateway.py &        # or run a real `jcode` gateway
python3 TestHarness/protocol_smoke_test.py --port 7643
```

## Mock board

The mock seeds four sessions per server (`needs_you` with a pending
`stdin_request`, `running`, `failed`, `idle`), `recent_projects`, a fake file
tree for `search_files`, and honours `list_sessions` pre-subscribe,
`close_session {delete}`, attach by `target_session_id` (history, then the
replayed `stdin_request`), `stdin_response` (→ `stdin_resolved`), `working_dir`
on `subscribe` (only paths in its fake tree), `images` and `active_skill` on
`message`. `--name`/`--icon` set the server chip. Two test-only requests:
`_notify` (push a notification + compaction) and `_prompt {prompt,
is_password}` (raise a `stdin_request` on the attached session).

## How auto-connect is seeded

The app stores paired servers in the Keychain, falling back to
`Library/Application Support/jcode-servers.json` when the Keychain is
unavailable (unsigned simulator builds). The harness writes that JSON directly
into the app's data container so the app auto-connects on launch, bypassing the
SpringBoard "Open in app?" deep-link confirmation that can't be scripted.

## Why this exists

`JCodeKit` (the platform-free client core) is fully unit-tested with `swift
test`. This harness adds the layer above that: it proves the real SwiftUI app,
running in a simulator, connects over a real WebSocket and renders a real
transcript. Together they make client behavior hill-climbable without a device.

## Measuring + improving the UI (efficiency reward)

"This looks ugly" is turned into a single hill-climbable number.

- **`ui_metrics.py`** - pixel-level scorer for one screenshot (space,
  consistency, legibility, rhythm) with `--annotate` overlays.
- **`ui_lint.py`** - source-level design-token discipline (hardcoded colors /
  fonts / off-grid spacing that bypass `Theme`).
- **`ui_matrix.py`** - renders the app across content scenarios
  (`empty,short,tool,long,code`) x devices x Dynamic Type sizes, scores each
  cell, reports a mean + worst cell. The mean is the hill to climb.
  - **Devices**: defaults to `iPhone 17` (large, 3x) plus
    `iPhone SE (3rd generation)` (small, 2x), so layout robustness is measured
    against real width/height pressure. Override with `--devices`.
  - **Dynamic Type**: the primary device is re-run at `accessibility-large`
    (via `simctl ui <dev> content_size`) so text-scaling breakage shows up in
    the matrix. Tune or disable with `--a11y-size ""`.
  - **Runtime perf**: each cell records best-effort runtime metrics in the
    schema `reward/scorers/perf.py` consumes: `cold_launch_ms` (wall time of
    `simctl launch` on a fresh install, i.e. a true cold launch) and
    `first_frame_ms` (screenshot polling until the app's background dominates
    the screen). Measurements include harness overhead, so treat them as
    consistent relative signals, not absolute truth. If measurement fails the
    cell omits `runtime` and the perf scorer degrades to unavailable
    (weights renormalize; the reward is never tanked by missing data).
    Skip with `--no-perf`. Scroll-jank capture is not implemented yet;
    `scroll_jank_frac` stays absent.
- **`reward/`** - the full UX reward framework. 13 scorers across 5 weighted
  categories (A space .30, B ergonomics .25, C clarity .20, D legibility/a11y
  .15, E responsiveness .10) aggregate into one 0-100 reward with a
  worst-category callout. See `reward/REWARD_SPEC.md`.

Typical loop:

```bash
# 1. capture a screenshot matrix + score it
python3 ui_matrix.py --json > /tmp/before.json
python3 -m reward.aggregate --matrix-json /tmp/before.json --out-json /tmp/before_reward.json

# 2. make a UI change, rebuild, re-measure
python3 ui_matrix.py --json > /tmp/after.json
python3 -m reward.aggregate --matrix-json /tmp/after.json --out-json /tmp/after_reward.json

# 3. gate: only keep the change if reward did not regress
python3 -m reward.aggregate --baseline /tmp/before_reward.json --candidate /tmp/after_reward.json

# scorers must stay pure/deterministic:
python3 -m reward.test_determinism
```

Adding a category is a one-file drop-in under `reward/scorers/` that satisfies
the contract (`NAME`, `CATEGORY`, `WEIGHT`, `score(ctx) -> CategoryScore`); the
aggregator discovers it automatically.
