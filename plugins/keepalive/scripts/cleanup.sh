#!/usr/bin/env bash
# SessionEnd : tue le timer keepalive de la session et nettoie son état.
SESSION_ID=$(jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
STATE_DIR=/tmp/claude-keepalive
[ -f "$STATE_DIR/$SESSION_ID.pid" ] && kill "$(cat "$STATE_DIR/$SESSION_ID.pid")" 2>/dev/null
rm -f "$STATE_DIR/$SESSION_ID".*
exit 0
