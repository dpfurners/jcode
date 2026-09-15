#!/usr/bin/env bash
#
# Sets the composer draft in the attached session (DEBUG builds only):
#   jcode://debug/compose?text=<text>
# The completion popup computes from the draft exactly as if typed, so
# "/gr" opens the slash list and "@comp" triggers one search_files request.
# Usage: type_composer.sh <device> <text>
set -euo pipefail
DEVICE="$1"; TEXT="$2"
enc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
"$(dirname "$0")/debug_url.sh" "$DEVICE" "jcode://debug/compose?text=$(enc "$TEXT")"
