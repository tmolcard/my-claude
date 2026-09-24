#!/usr/bin/env bash
# Commande /keepalive, sourcée par keepalive.sh qui a déjà lu l'entrée du hook et
# posé les chemins d'état de la session.
#
# La réponse sort en {"decision":"block","reason":…} : Claude Code affiche la
# raison et abandonne le prompt, qui n'atteint donc jamais le modèle.

HELP="Commandes : /keepalive [status] · on · off · now · delay 30m|1h|reset · prompt <texte>|reset · stats on|off|reset · max <N>|reset (0 = sans limite) · reset"

reply() { jq -n --arg r "$1" '{decision:"block",reason:$r}'; }

# « 55 min », « 1 h 30 », « 45 s »
fmt_dur() {
  local s=$1 m
  [ "$s" -lt 60 ] && { echo "$s s"; return; }
  m=$(( (s + 30) / 60 ))
  [ "$m" -lt 60 ] && { echo "$m min"; return; }
  printf '%d h %02d\n' $((m / 60)) $((m % 60))
}

# Heure locale d'un epoch, GNU (Linux) puis BSD (macOS).
clock() { date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null; }

# « 30m », « 30min », « 1h », « 1h30 », « 90s », « 45 » (minutes) → secondes
parse_dur() {
  local v=${1// /}
  if   [[ $v =~ ^([0-9]+)h([0-9]+)?(m|min)?$ ]]; then echo $(( BASH_REMATCH[1] * 3600 + ${BASH_REMATCH[2]:-0} * 60 ))
  elif [[ $v =~ ^([0-9]+)(m|min)?$ ]];          then echo $(( BASH_REMATCH[1] * 60 ))
  elif [[ $v =~ ^([0-9]+)s$ ]];                 then echo "${BASH_REMATCH[1]}"
  else return 1; fi
}

timer_alive() {
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  ps -o command= -p "$pid" 2>/dev/null | grep -q 'keepalive\.sh'
}

# Réarme en gardant l'échéance calée sur la dernière vraie activité : passer de
# 55 à 30 min après 40 min de silence doit pinger tout de suite, pas dans 30 min.
rearm() {
  local now last rem
  can_arm || return 0
  [ -f "$OFF_FILE" ] && return 0
  cap_reached && { kill_timer "$PID_FILE"; rm -f "$PID_FILE" "$DUE_FILE"; return 0; }
  now=$(date +%s)
  last=$(cat "$LAST_FILE" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=$now ;; esac
  rem=$(( last + DELAY - now ))
  [ "$rem" -lt 3 ] && rem=3
  arm_timer "$rem"
}

# Une ligne d'état : ce qui va se passer, et pourquoi.
state_line() {
  local due now
  if [ "${KEEPALIVE_DISABLE:-0}" = "1" ]; then
    echo "désactivé : KEEPALIVE_DISABLE=1 dans l'environnement de claude"
  elif [ -z "${TMUX_PANE:-}" ] || ! command -v tmux >/dev/null; then
    echo "inactif : cette session ne tourne pas dans tmux"
  elif [ -f "$OFF_FILE" ]; then
    echo "coupé pour cette session (/keepalive on pour reprendre)"
  elif timer_alive; then
    now=$(date +%s); due=$(cat "$DUE_FILE" 2>/dev/null)
    case "$due" in ''|*[!0-9]*) echo "actif · timer armé" ;;
      *) [ "$due" -lt "$now" ] && due=$now
         echo "actif · prochain ping dans $(fmt_dur $(( due - now ))) (vers $(clock "$due"))" ;;
    esac
  elif cap_reached; then
    echo "en pause : plafond de $MAX pings d'affilée atteint, ton prochain message le relance"
  elif [ ! -f "$LAST_FILE" ]; then
    echo "actif · aucun tour depuis le démarrage : le timer s'armera à la fin du premier"
  else
    # Le timer a expiré sans pinger : la saisie était occupée (brouillon, dialogue).
    echo "actif · dernier ping sauté (saisie occupée) : le timer se réarme à la fin du prochain tour, ou /keepalive now"
  fi
}

# Provenance d'un réglage : cette session, l'environnement, ou le défaut.
src() { if [ -f "$1" ]; then echo " (session)"; elif [ -n "$2" ]; then echo " (env)"; fi; }

status_text() {
  local max_txt stats_txt prompt_txt count
  [ "$MAX" -gt 0 ] && max_txt="$MAX" || max_txt="aucun"
  [ "$STATS" = "1" ] && stats_txt="oui" || stats_txt="non"
  count=$(cat "$CNT_FILE" 2>/dev/null || echo 0)
  if [ -s "$PROMPT_FILE" ] || [ -n "${KEEPALIVE_PROMPT:-}" ]; then
    prompt_txt="« ${PROMPT_MSG:0:160}$([ ${#PROMPT_MSG} -gt 160 ] && echo …) »$(src "$PROMPT_FILE" "${KEEPALIVE_PROMPT:-}")"
  else
    prompt_txt="par défaut (relecture de la mission, cas 1/2/3)"
  fi
  printf 'keepalive : %s\ndélai %s%s · plafond %s%s · stats %s%s · pings d%saffilée %s\nprompt : %s\n%s' \
    "$(state_line)" \
    "$(fmt_dur "$DELAY")" "$(src "$DELAY_FILE" "${KEEPALIVE_DELAY:-}")" \
    "$max_txt" "$(src "$MAX_FILE" "${KEEPALIVE_MAX_PINGS:-}")" \
    "$stats_txt" "$(src "$STATS_FILE" "${KEEPALIVE_STATS:-}")" \
    "'" "$count" "$prompt_txt" "$HELP"
}

handle_command() {
  local args sub rest secs warn
  args=${1#/keepalive:keepalive}; args=${args#/keepalive}
  args=${args#"${args%%[![:space:]]*}"}
  sub=${args%%[[:space:]]*}
  rest=${args#"$sub"}; rest=${rest#"${rest%%[![:space:]]*}"}
  load_config

  case "$sub" in
    ""|status)
      reply "$(status_text)" ;;

    off)
      touch "$OFF_FILE"
      kill_timer "$PID_FILE"; rm -f "$PID_FILE" "$DUE_FILE"
      reply "keepalive coupé pour cette session, plus aucun ping. /keepalive on pour reprendre." ;;

    on)
      rm -f "$OFF_FILE"
      echo 0 > "$CNT_FILE"        # reprendre, c'est aussi repartir d'un compteur neuf
      rearm
      reply "keepalive : $(state_line)" ;;

    now)
      if ! can_arm || [ -f "$OFF_FILE" ]; then reply "keepalive : $(state_line)"
      else arm_timer 3; reply "keepalive : ping dans 3 s."; fi ;;

    delay)
      case "$rest" in
        "")    reply "délai : $(fmt_dur "$DELAY")$(src "$DELAY_FILE" "${KEEPALIVE_DELAY:-}")" ; return ;;
        reset) rm -f "$DELAY_FILE" ;;
        *)     secs=$(parse_dur "$rest") && [ "$secs" -ge 10 ] ||
                 { reply "durée non comprise : « $rest ». Exemples : 30m, 1h, 1h30, 90s (minimum 10 s)."; return; }
               echo "$secs" > "$DELAY_FILE" ;;
      esac
      load_config; rearm
      [ "$DELAY" -ge 3600 ] && warn=$'\n'"attention : au-delà de 60 min, le cache (TTL 1 h) aura expiré avant le ping."
      reply "délai : $(fmt_dur "$DELAY")$(src "$DELAY_FILE" "${KEEPALIVE_DELAY:-}") · $(state_line)$warn" ;;

    prompt)
      case "$rest" in
        "")    ;;
        reset) rm -f "$PROMPT_FILE" ;;
        *)     printf '%s' "$rest" > "$PROMPT_FILE" ;;
      esac
      load_config
      reply "prompt$([ -n "$rest" ] && echo " (appliqué dès le prochain ping)") : « $PROMPT_MSG »" ;;

    stats)
      case "$rest" in
        on|1)  echo 1 > "$STATS_FILE" ;;
        off|0) echo 0 > "$STATS_FILE" ;;
        reset) rm -f "$STATS_FILE" ;;
        "")    ;;
        *)     reply "stats : on, off ou reset."; return ;;
      esac
      load_config
      reply "stats machine jointes au ping : $([ "$STATS" = 1 ] && echo oui || echo non)$(src "$STATS_FILE" "${KEEPALIVE_STATS:-}")" ;;

    max)
      case "$rest" in
        reset) rm -f "$MAX_FILE" ;;
        "")    ;;
        *[!0-9]*) reply "max : un nombre de pings d'affilée (0 = sans limite), ou reset."; return ;;
        *)     echo "$rest" > "$MAX_FILE" ;;
      esac
      load_config; [ -n "$rest" ] && rearm
      reply "plafond : $([ "$MAX" -gt 0 ] && echo "$MAX pings d'affilée" || echo "aucun")$(src "$MAX_FILE" "${KEEPALIVE_MAX_PINGS:-}") · $(state_line)" ;;

    reset)
      rm -f "$OFF_FILE" "$DELAY_FILE" "$PROMPT_FILE" "$STATS_FILE" "$MAX_FILE"
      load_config; rearm
      reply "réglages de session effacés, retour aux valeurs d'env/défaut."$'\n'"$(status_text)" ;;

    help|-h|--help)
      reply "$HELP" ;;

    *)
      reply "sous-commande inconnue : « $sub »."$'\n'"$HELP" ;;
  esac
}
