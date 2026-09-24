#!/usr/bin/env bash
# Keepalive du cache 1h : debounce relancé à chaque activité (Stop / UserPromptSubmit).
# Si le timer expire sans activité, injecte un ping dans le pane tmux de la session.
#
# Config par variables d'env (valeurs par défaut de toutes les sessions) :
#   KEEPALIVE_DELAY      secondes avant ping (défaut 3300 = 55 min)
#   KEEPALIVE_MAX_PINGS  pings consécutifs sans activité humaine avant abandon
#                        (défaut 0 = sans limite, on ping tant que la session vit)
#   KEEPALIVE_PROMPT     texte du ping ; le préfixe [keepalive] est ajouté s'il manque
#   KEEPALIVE_STATS      1 (défaut) joint un instantané CPU/RAM/disque/GPU au ping, 0 l'omet
#   KEEPALIVE_DISABLE=1  désactive complètement
#
# Réglages par session : la commande /keepalive (voir control.sh) les écrit dans
# le répertoire d'état, où ils priment sur les variables d'env.

command -v jq >/dev/null || exit 0
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Le préfixe est la signature qui distingue nos pings d'un vrai message, pour le
# compteur. Il survit à un changement de texte et à l'ajout des stats, d'où son
# ajout d'office si un prompt personnalisé l'oublie.
PREFIX="[keepalive]"
DEFAULT_PROMPT="[keepalive] Réveil automatique après inactivité. Relis la mission confiée dans cette session. Cas 1 : aucune mission en cours, ou tout est terminé → réponds uniquement \"OK\". Cas 2 : des runs que tu as lancées tournent encore → vérifie brièvement qu'elles sont vivantes et progressent (pgrep, queue, dernières lignes de log) ; réponds \"OK\", ou signale en une ligne ce qui a planté. Cas 3 : la mission t'autorise à enchaîner (ex. recherche d'hyperparamètres) et les ressources sont libres → prends du recul : compare les derniers résultats aux précédents, choisis la prochaine run selon les critères fixés dans la mission, lance-la, et résume en deux lignes ce que tu as appris et ce que tu lances. Dans tous les cas : ne sors pas du périmètre défini avant la loop, et si le budget ou le critère d'arrêt est atteint, ou si deux runs consécutives ont échoué pour la même raison, ne relance pas — dis-le en une ligne et attends."

INPUT=$(cat)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT")
EVENT=$(jq -r '.hook_event_name // empty' <<<"$INPUT")
PROMPT=$(jq -r '.prompt // empty' <<<"$INPUT")
[ -n "$SESSION_ID" ] || exit 0

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
S="$STATE_DIR/$SESSION_ID"
PID_FILE=$S.pid CNT_FILE=$S.count DUE_FILE=$S.due LAST_FILE=$S.last
OFF_FILE=$S.off DELAY_FILE=$S.delay MAX_FILE=$S.max STATS_FILE=$S.stats PROMPT_FILE=$S.prompt

# Config effective : variables d'env, puis surcharges de la session. Relue aussi
# par le timer au moment du ping, pour qu'un /keepalive prompt ou stats tapé
# entre-temps s'applique sans devoir réarmer.
load_config() {
  local v
  DELAY=${KEEPALIVE_DELAY:-3300}
  MAX=${KEEPALIVE_MAX_PINGS:-0}
  # Une valeur non numérique retomberait en silence sur un `sleep` en erreur ou un
  # plafond ignoré : on revient aux défauts plutôt que de désactiver sans le dire.
  case "$DELAY" in ''|*[!0-9]*) DELAY=3300 ;; esac
  case "$MAX"   in ''|*[!0-9]*) MAX=0     ;; esac
  STATS=0; [ "${KEEPALIVE_STATS:-1}" = "1" ] && STATS=1
  PROMPT_MSG=${KEEPALIVE_PROMPT:-$DEFAULT_PROMPT}

  v=$(cat "$DELAY_FILE" 2>/dev/null); case "$v" in ''|*[!0-9]*) ;; *) DELAY=$v ;; esac
  v=$(cat "$MAX_FILE"   2>/dev/null); case "$v" in ''|*[!0-9]*) ;; *) MAX=$v   ;; esac
  v=$(cat "$STATS_FILE" 2>/dev/null); case "$v" in 0|1) STATS=$v ;; esac
  [ -s "$PROMPT_FILE" ] && PROMPT_MSG=$(cat "$PROMPT_FILE")

  case "$PROMPT_MSG" in "$PREFIX"*) ;; *) PROMPT_MSG="$PREFIX $PROMPT_MSG" ;; esac
  # Un retour à la ligne validerait la saisie à mi-chemin : on l'aplatit en espace.
  PROMPT_MSG=$(printf '%s' "$PROMPT_MSG" | tr '\n\r' '  ')
}

cap_reached() {
  [ "$MAX" -gt 0 ] && [ "$(cat "$CNT_FILE" 2>/dev/null || echo 0)" -ge "$MAX" ]
}

# Nouveau timer. Les stats sont relevées au moment du ping, pas maintenant :
# elles ne valent que si elles décrivent l'instant où le modèle décide.
# `set -m` place le sous-shell dans son propre groupe de process : un signal
# envoyé au groupe du hook quand celui-ci rend la main ne l'emporte pas avec lui.
arm_timer() {
  local secs=$1
  kill_timer "$PID_FILE"
  rm -f "$PID_FILE" "$DUE_FILE"
  set -m
  (
    sleep "$secs"
    [ -f "$OFF_FILE" ] && exit 0
    pane_is_idle "$TMUX_PANE" || exit 0
    load_config
    MSG=$PROMPT_MSG
    if [ "$STATS" = "1" ]; then
      SNAP=$(resource_snapshot)
      [ -n "$SNAP" ] && MSG="$MSG Ressources machine à cet instant : $SNAP."
    fi
    send_prompt "$TMUX_PANE" "$MSG"
  ) >/dev/null 2>&1 &
  echo $! > "$PID_FILE"
  echo $(( $(date +%s) + secs )) > "$DUE_FILE"
  disown
  set +m
}

# Le hook peut-il armer un timer dans cette session ?
can_arm() {
  [ "${KEEPALIVE_DISABLE:-0}" != "1" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null
}

# /keepalive … : traité ici puis bloqué, le modèle ne le voit jamais (aucun
# token, aucun tour). Ce n'est pas une activité : le cache n'est pas rafraîchi,
# donc ni le compteur ni l'horodatage de dernière activité ne bougent.
if [ "$EVENT" = "UserPromptSubmit" ]; then
  case "$(unwrap_prompt "$PROMPT")" in
    /keepalive|"/keepalive "*|/keepalive:keepalive|"/keepalive:keepalive "*)
      . "$(dirname "${BASH_SOURCE[0]}")/control.sh"
      handle_command "$(unwrap_prompt "$PROMPT")"
      exit 0 ;;
  esac
fi

can_arm || exit 0
load_config
date +%s > "$LAST_FILE"

# Compteur de pings consécutifs, remis à zéro par une vraie activité humaine.
# Tout UserPromptSubmit n'est pas humain : la fin d'un subagent en arrière-plan
# est réinjectée dans la session sous forme de prompt `<task-notification>`.
# Un tel tour rafraîchit bien le cache — le timer est donc relancé plus bas,
# comme pour n'importe quelle activité — mais il ne doit pas remettre le
# compteur à zéro : personne n'est revenu devant le clavier.
if [ "$EVENT" = "UserPromptSubmit" ]; then
  case "$(unwrap_prompt "$PROMPT")" in
    "$PREFIX"*)             # notre propre ping
      echo $(( $(cat "$CNT_FILE" 2>/dev/null || echo 0) + 1 )) > "$CNT_FILE" ;;
    "<task-notification>"*) # prompt injecté par le système, pas par toi
      ;;
    *)                      # message humain
      echo 0 > "$CNT_FILE" ;;
  esac
fi

# Annule le timer précédent
kill_timer "$PID_FILE"
rm -f "$PID_FILE" "$DUE_FILE"

# Coupé pour cette session par /keepalive off : on suit l'activité, sans armer.
[ -f "$OFF_FILE" ] && exit 0

# Plafond optionnel, désactivé par défaut (MAX=0) : on ping tant que la session
# est en vie. Le cas 0 est explicite car sinon le test -ge le prendrait pour un
# plafond atteint d'emblée et ne pingerait jamais.
cap_reached && exit 0

arm_timer "$DELAY"
exit 0
