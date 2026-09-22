#!/usr/bin/env bash
# Keepalive du cache 1h : debounce relancé à chaque activité (Stop / UserPromptSubmit).
# Si le timer expire sans activité, injecte un ping dans le pane tmux de la session.
#
# Config par variables d'env :
#   KEEPALIVE_DELAY      secondes avant ping (défaut 3300 = 55 min)
#   KEEPALIVE_MAX_PINGS  pings consécutifs sans activité humaine avant abandon (défaut 12 ≈ 11h)
#   KEEPALIVE_DISABLE=1  désactive complètement

[ "${KEEPALIVE_DISABLE:-0}" = "1" ] && exit 0
command -v jq >/dev/null && command -v tmux >/dev/null || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0   # hors tmux : rien à faire

DELAY=${KEEPALIVE_DELAY:-3300}
MAX=${KEEPALIVE_MAX_PINGS:-12}
PING_MSG="ping keepalive — réponds uniquement OK"

INPUT=$(cat)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
EVENT=$(jq -r '.hook_event_name // empty' <<<"$INPUT")
PROMPT=$(jq -r '.prompt // empty' <<<"$INPUT")
[ -n "$SESSION_ID" ] || exit 0

STATE_DIR=/tmp/claude-keepalive
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/$SESSION_ID.pid"
CNT_FILE="$STATE_DIR/$SESSION_ID.count"

# Compteur de pings consécutifs : remis à zéro par une vraie activité humaine
if [ "$EVENT" = "UserPromptSubmit" ]; then
  if [ "$PROMPT" = "$PING_MSG" ]; then
    echo $(( $(cat "$CNT_FILE" 2>/dev/null || echo 0) + 1 )) > "$CNT_FILE"
  else
    echo 0 > "$CNT_FILE"
  fi
fi

# Annule le timer précédent
[ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null

# Plafond atteint : on laisse le cache expirer
[ "$(cat "$CNT_FILE" 2>/dev/null || echo 0)" -ge "$MAX" ] && exit 0

# Nouveau timer
(
  sleep "$DELAY"
  tmux send-keys -t "$TMUX_PANE" "$PING_MSG" Enter
) >/dev/null 2>&1 &
echo $! > "$PID_FILE"
disown
exit 0
