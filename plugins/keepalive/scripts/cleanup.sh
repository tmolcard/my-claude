#!/usr/bin/env bash
# SessionEnd : tue le timer keepalive de la session et nettoie son état d'exécution.
# Les réglages posés par /keepalive (off, delay, prompt, stats, max) sont gardés :
# `claude --resume` reprend le même session_id, et un `off` doit survivre au
# redémarrage plutôt que de repartir en pings sans prévenir.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
SESSION_ID=$(jq -r '.session_id // empty')
[ -n "$SESSION_ID" ] || exit 0
kill_timer "$STATE_DIR/$SESSION_ID.pid"
rm -f "$STATE_DIR/$SESSION_ID".{pid,count,due,last}
exit 0
