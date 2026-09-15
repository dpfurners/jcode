#!/usr/bin/env bash
#
# Attaches the running app to a session by deep link:
#   jcode://session?host=127.0.0.1&id=<session_id>
# The app matches `host` against a seeded server's literal host, first DNS
# label, or server name. Delivered through debug_url.sh (no SpringBoard
# prompt); set JCODE_USE_OPENURL=1 to go through `simctl openurl` instead.
# Usage: attach.sh <device> <session_id> [host]
set -euo pipefail
DEVICE="$1"; SESSION_ID="$2"; HOST="${3:-127.0.0.1}"
URL="jcode://session?host=$HOST&id=$SESSION_ID"
if [[ "${JCODE_USE_OPENURL:-0}" == "1" ]]; then
  xcrun simctl openurl "$DEVICE" "$URL"
else
  "$(dirname "$0")/debug_url.sh" "$DEVICE" "$URL"
fi
