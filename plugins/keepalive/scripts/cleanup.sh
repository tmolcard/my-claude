#!/usr/bin/env bash
# SessionEnd : tue le timer keepalive de la session et nettoie son état.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
SESSION_ID=$(jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
kill_timer "$STATE_DIR/$SESSION_ID.pid"
rm -f "$STATE_DIR/$SESSION_ID".*
exit 0
