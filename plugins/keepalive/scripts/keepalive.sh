#!/usr/bin/env bash
# Keepalive du cache 1h : debounce relancé à chaque activité (Stop / UserPromptSubmit).
# Si le timer expire sans activité, injecte un ping dans le pane tmux de la session.
#
# Config par variables d'env :
#   KEEPALIVE_DELAY      secondes avant ping (défaut 3300 = 55 min)
#   KEEPALIVE_MAX_PINGS  pings consécutifs sans activité humaine avant abandon
#                        (défaut 0 = sans limite, on ping tant que la session vit)
#   KEEPALIVE_DISABLE=1  désactive complètement

[ "${KEEPALIVE_DISABLE:-0}" = "1" ] && exit 0
command -v jq >/dev/null && command -v tmux >/dev/null || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0   # hors tmux : rien à faire

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

DELAY=${KEEPALIVE_DELAY:-3300}
MAX=${KEEPALIVE_MAX_PINGS:-0}
# Une valeur non numérique retomberait en silence sur un `sleep` en erreur ou un
# plafond ignoré : on revient aux défauts plutôt que de désactiver sans le dire.
case "$DELAY" in ''|*[!0-9]*) DELAY=3300 ;; esac
case "$MAX"   in ''|*[!0-9]*) MAX=0     ;; esac
PING_MSG="ping keepalive — réponds uniquement OK"

INPUT=$(cat)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
EVENT=$(jq -r '.hook_event_name // empty' <<<"$INPUT")
PROMPT=$(jq -r '.prompt // empty' <<<"$INPUT")
[ -n "$SESSION_ID" ] || exit 0

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
PID_FILE="$STATE_DIR/$SESSION_ID.pid"
CNT_FILE="$STATE_DIR/$SESSION_ID.count"

# Compteur de pings consécutifs, remis à zéro par une vraie activité humaine.
# Tout UserPromptSubmit n'est pas humain : la fin d'un subagent en arrière-plan
# est réinjectée dans la session sous forme de prompt `<task-notification>`.
# Un tel tour rafraîchit bien le cache — le timer est donc relancé plus bas,
# comme pour n'importe quelle activité — mais il ne doit pas remettre le
# compteur à zéro : personne n'est revenu devant le clavier.
if [ "$EVENT" = "UserPromptSubmit" ]; then
  case "$PROMPT" in
    "$PING_MSG")            # notre propre ping
      echo $(( $(cat "$CNT_FILE" 2>/dev/null || echo 0) + 1 )) > "$CNT_FILE" ;;
    "<task-notification>"*) # prompt injecté par le système, pas par toi
      ;;
    *)                      # message humain
      echo 0 > "$CNT_FILE" ;;
  esac
fi

# Annule le timer précédent
kill_timer "$PID_FILE"
rm -f "$PID_FILE"

# Plafond optionnel, désactivé par défaut (MAX=0) : on ping tant que la session
# est en vie. Le cas 0 est explicite car sinon le test -ge le prendrait pour un
# plafond atteint d'emblée et ne pingerait jamais.
if [ "$MAX" -gt 0 ]; then
  [ "$(cat "$CNT_FILE" 2>/dev/null || echo 0)" -ge "$MAX" ] && exit 0
fi

# Nouveau timer
(
  sleep "$DELAY"
  pane_is_idle "$TMUX_PANE" || exit 0
  tmux send-keys -t "$TMUX_PANE" "$PING_MSG" Enter
) >/dev/null 2>&1 &
echo $! > "$PID_FILE"
disown
exit 0
