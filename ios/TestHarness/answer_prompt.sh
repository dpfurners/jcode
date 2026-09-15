#!/usr/bin/env bash
#
# Answers the pending prompt in the attached session (DEBUG builds only):
#   jcode://debug/answer?request_id=<id>&text=<text>
# Goes through the same stdin_response path as the prompt card's Send. The
# request_id must match the prompt the app currently shows (pass "" to skip
# the check). Usage: answer_prompt.sh <device> <request_id> <text>
set -euo pipefail
DEVICE="$1"; REQUEST_ID="$2"; TEXT="$3"
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
"$(dirname "$0")/debug_url.sh" "$DEVICE" \
  "jcode://debug/answer?request_id=$(enc "$REQUEST_ID")&text=$(enc "$TEXT")"
