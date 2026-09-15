#!/usr/bin/env bash
#
# Seeds a paired ServerCredential into the installed app's data container so
# the app trusts the server without the SpringBoard "Open in app?" deep-link
# confirmation. Appends to any credentials already seeded.
#
# Usage: seed_credential.sh <device> <host> <port> <token> <server_name>
#
# The app reads Keychain first and falls back to
# Library/Application Support/jcode-servers.json (unsigned simulator builds
# get errSecMissingEntitlement), which is what this writes.
set -euo pipefail
DEVICE="$1"; HOST="$2"; PORT="$3"; TOKEN="$4"; NAME="$5"
BUNDLE_ID="${BUNDLE_ID:-com.jcode.mobile}"
CONTAINER="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
APPSUP="$CONTAINER/Library/Application Support"
mkdir -p "$APPSUP"
FILE="$APPSUP/jcode-servers.json"
python3 - "$FILE" "$HOST" "$PORT" "$TOKEN" "$NAME" <<'PY'
import json, sys
path, host, port, token, name = sys.argv[1:]
try:
    creds = json.load(open(path))
except Exception:
    creds = []
creds = [c for c in creds if not (c["host"] == host and c["port"] == int(port))]
creds.append({"host": host, "port": int(port), "token": token, "serverName": name,
              "serverVersion": "mock-0.32.0", "pairedAt": 770000000})
json.dump(creds, open(path, "w"))
PY
