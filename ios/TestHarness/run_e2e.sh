#!/usr/bin/env bash
#
# End-to-end iOS harness: builds the app, runs the deterministic mock gateway,
# boots a simulator, seeds a paired-server credential, launches the app, and
# captures a screenshot proving the live connection + transcript render.
#
# This gives agents a verifiable, repeatable target to develop the client
# against without an LLM, network, or manual device steps.
#
# Usage:
#   ./TestHarness/run_e2e.sh [--device "iPhone 17"] [--push-demo]
#
set -euo pipefail

cd "$(dirname "$0")/.."        # ios/
HARNESS="TestHarness"
DEVICE="iPhone 17"
PUSH_DEMO=""
BUNDLE_ID="com.jcode.mobile"
PORT=7643
PORT2=7644
SHOT_DIR="${TMPDIR:-/tmp}/jcode-ios-e2e"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --push-demo) PUSH_DEMO="--push-demo"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$SHOT_DIR"

log() { printf '\033[36m[e2e]\033[0m %s\n' "$*"; }

cleanup() {
  [[ -n "${GW_PID:-}" ]] && kill "$GW_PID" 2>/dev/null || true
  [[ -n "${GW2_PID:-}" ]] && kill "$GW2_PID" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Swift unit tests (headless behavior layer).
log "swift test"
swift test 2>&1 | tail -1

# 2. Build the app for the simulator.
log "xcodegen + xcodebuild ($DEVICE)"
xcodegen generate >/dev/null
xcodebuild build \
  -project JCodeMobile.xcodeproj \
  -scheme JCodeMobile \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath .build-ios >/dev/null
APP=".build-ios/Build/Products/Debug-iphonesimulator/JCodeMobile.app"

# 3. Start two deterministic mock gateways so the board shows two servers.
log "starting mock gateways on :$PORT and :$PORT2 $PUSH_DEMO"
pkill -f mock_gateway.py 2>/dev/null || true
sleep 0.5
python3 "$HARNESS/mock_gateway.py" --port "$PORT" --host 127.0.0.1 $PUSH_DEMO \
  --name home-mini --icon "🏠" >"$SHOT_DIR/mockgw.log" 2>&1 &
GW_PID=$!
python3 "$HARNESS/mock_gateway.py" --port "$PORT2" --host 127.0.0.1 \
  --name work-mini --icon "🔥" --token mocktoken2 >"$SHOT_DIR/mockgw2.log" 2>&1 &
GW2_PID=$!
sleep 1.5

# 4. Protocol smoke test (asserts full message/tool/markdown sequence).
log "protocol smoke test"
python3 "$HARNESS/protocol_smoke_test.py" --port "$PORT" | tail -1

# 5. Boot the simulator (idempotent).
log "booting simulator: $DEVICE"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
sleep 3

# 6. Install fresh + seed two paired-server credentials (one per mock), plus a
#    third that points at a closed port so the "unreachable" header renders.
log "installing app + seeding credentials"
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
"$HARNESS/seed_credential.sh" "$DEVICE" 127.0.0.1 "$PORT" mocktoken0123456789abcdef home-mini
"$HARNESS/seed_credential.sh" "$DEVICE" 127.0.0.1 "$PORT2" mocktoken2 work-mini
"$HARNESS/seed_credential.sh" "$DEVICE" 127.0.0.1 7699 dead laptop

# 7. Launch: the board polls both servers. Screenshot it.
log "launching app"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID" >/dev/null
sleep 6
SHOT="$SHOT_DIR/board.png"
xcrun simctl io "$DEVICE" screenshot "$SHOT" >/dev/null 2>&1
log "screenshot (board): $SHOT"

# 8. Deep-link into the needs_you session on work-mini (the smoke test already
#    answered home-mini's prompt), matched by server name: history +
#    replayed stdin_request render the inline prompt card.
log "attaching via deep link"
"$HARNESS/attach.sh" "$DEVICE" mock-session-0002 work-mini
sleep 4
SHOT="$SHOT_DIR/chat.png"
xcrun simctl io "$DEVICE" screenshot "$SHOT" >/dev/null 2>&1
log "screenshot (attached, pending prompt): $SHOT"
log "gateway logs: $SHOT_DIR/mockgw.log $SHOT_DIR/mockgw2.log"
log "done"
