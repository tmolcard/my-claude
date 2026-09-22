#!/usr/bin/env bash
# Fonctions et état partagés par keepalive.sh et cleanup.sh.

# Répertoire d'état, isolé par utilisateur : /tmp est partagé, et le premier
# utilisateur à créer le dossier en deviendrait propriétaire exclusif.
# Surchargeable par KEEPALIVE_STATE_DIR, ce dont la suite de tests a besoin pour
# ne pas piétiner l'état des sessions réelles en cours.
STATE_DIR="${KEEPALIVE_STATE_DIR:-/tmp/claude-keepalive-$(id -u)}"

# Tue le timer d'une session : d'abord le `sleep` enfant (sinon il survit à son
# parent et s'accumule à chaque hook), puis le sous-shell lui-même.
# Garde anti-réutilisation de PID : un fichier .pid périmé (session tuée sans
# SessionEnd, machine redémarrée) peut pointer vers un process sans rapport, on
# ne signale donc que ce qui est bien un de nos timers.
kill_timer() {
  local pid_file=$1 pid
  [ -f "$pid_file" ] || return 0
  pid=$(cat "$pid_file" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  ps -o command= -p "$pid" 2>/dev/null | grep -q 'keepalive\.sh' || return 0
  pkill -P "$pid" 2>/dev/null
  kill "$pid" 2>/dev/null
}

# Le pane est-il prêt à recevoir un ping ? On exige une boîte de saisie vide.
# Sans ce garde-fou, `send-keys … Enter` sur un pane occupé soit écrase un
# brouillon en cours de frappe, soit — bien plus grave — valide un dialogue de
# permission resté ouvert : le texte du ping est ignoré, mais Enter confirme
# l'option surlignée (« 1. Yes ») et la commande s'exécute sans accord humain.
# En cas de doute on s'abstient : au pire le cache expire, ce qui ne coûte
# qu'une réécriture.
pane_is_idle() {
  local pane=$1 marker rest
  marker=$(tmux capture-pane -p -t "$pane" 2>/dev/null | grep '❯' | tail -1) || return 1
  [ -n "$marker" ] || return 1          # boîte de saisie introuvable
  rest=${marker#*❯}                      # ce qui suit le chevron : doit être vide
  [ -z "$(printf '%s' "$rest" | tr -d '[:space:]')" ]
}
