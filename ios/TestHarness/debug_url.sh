#!/usr/bin/env bash
#
# Delivers a jcode:// URL to the running DEBUG app without SpringBoard's
# "Open in jcode?" confirmation: appends it to <container>/tmp/jcode-debug-url,
# which the app polls every 250 ms and routes through its onOpenURL handler.
# Usage: debug_url.sh <device> <url>
set -euo pipefail
DEVICE="$1"; URL="$2"
BUNDLE_ID="${BUNDLE_ID:-com.jcode.mobile}"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
mkdir -p "$CONTAINER/tmp"
printf '%s\n' "$URL" >> "$CONTAINER/tmp/jcode-debug-url"
