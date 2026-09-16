#!/usr/bin/env bash
#
# Prints the DEBUG app's sync dump (Documents/sync-dump.json), written when
# the app was launched with SIMCTL_CHILD_JCODE_SYNC_DUMP=1. Shape and
# semantics: README.md "Sync dump". Usage: read_sync_dump.sh <device>
set -euo pipefail
DEVICE="$1"
BUNDLE_ID="${BUNDLE_ID:-com.jcode.mobile}"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
cat "$CONTAINER/Documents/sync-dump.json"
