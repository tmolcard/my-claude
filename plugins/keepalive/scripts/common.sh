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

# Instantané des ressources machine, joint au ping pour que le modèle puisse
# juger s'il a de quoi enchaîner une run. Chaque mesure est best-effort : ce que
# la machine ne sait pas donner est omis, jamais remonté en erreur. Sur macOS le
# GPU n'est pas lisible sans sudo (powermetrics), il est donc simplement absent.
resource_snapshot() {
  local os parts=() load ncpu ram disk gpu
  os=$(uname -s 2>/dev/null)

  case "$os" in
    Darwin)
      load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
      ncpu=$(sysctl -n hw.ncpu 2>/dev/null)
      ram=$(vm_stat 2>/dev/null | awk -v total="$(sysctl -n hw.memsize 2>/dev/null)" '
        /page size of/                 { ps=$8 }
        /Pages active/                 { a=$3+0 }
        /Pages wired down/             { w=$4+0 }
        /Pages occupied by compressor/ { c=$5+0 }
        END { if (ps>0 && total>0) printf "%.1f/%.0f Go", (a+w+c)*ps/1073741824, total/1073741824 }') ;;
    Linux)
      load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
      ncpu=$(nproc 2>/dev/null)
      ram=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
                 END { if (t>0) printf "%.1f/%.0f Go", (t-a)/1048576, t/1048576 }' /proc/meminfo 2>/dev/null) ;;
  esac

  load=${load//,/.}   # certaines locales rendent la charge avec une virgule
  [ -n "$load" ] && parts+=("charge ${load} sur ${ncpu:-?} coeurs")
  [ -n "$ram"  ] && parts+=("RAM $ram")

  disk=$(df -h . 2>/dev/null | tail -1 | awk '{print $5" occupe, "$4" libres"}')
  [ -n "$disk" ] && parts+=("disque $disk")

  # GPU : c'est l'info décisive pour savoir si on peut enchainer une run, donc on
  # agrège toutes les cartes et on dit surtout combien sont libres. Une carte est
  # comptée libre en dessous de 5 % d'utilisation et 5 % de VRAM occupée.
  gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null |
        awk -F'[,[:space:]]+' '
          NF>=3 && $3+0>0 { n++; u+=$1; mu+=$2; mt+=$3
                            if ($1+0 < 5 && $2 < 0.05*$3) free++ }
          END { if (n==1) printf "GPU %d%% · VRAM %.0f/%.0f Go", u, mu/1024, mt/1024
                else if (n>1) printf "%d GPU (%d libres) · util moy %d%% · VRAM %.0f/%.0f Go", n, free, u/n, mu/1024, mt/1024 }')
  [ -n "$gpu" ] && parts+=("$gpu")

  [ ${#parts[@]} -eq 0 ] && return 0
  # Jointure à la main : "${parts[*]}" ne colle qu'avec le premier caractère
  # d'IFS, un séparateur de plusieurs caractères y serait tronqué.
  local out="${parts[0]}" i
  for i in "${parts[@]:1}"; do out="$out · $i"; done
  # Décimales a la virgule selon la locale : on ne touche qu'aux virgules
  # encadrées de chiffres, pas a celles de la ponctuation.
  printf '%s' "$out" | sed 's/\([0-9]\),\([0-9]\)/\1.\2/g'
}

# Envoi du ping dans le pane. On passe par un buffer tmux et un collage bracketé
# plutôt que par `send-keys -l` : au-delà de quelques dizaines de caractères,
# send-keys perd le DÉBUT du message (mesuré : sur ~900 caractères, seuls les
# ~60 derniers arrivent, préfixe compris). Le buffer est nommé et supprimé après
# usage pour ne pas marcher sur les presse-papiers tmux de l'utilisateur.
send_prompt() {
  local pane=$1 msg=$2
  printf '%s' "$msg" | tmux load-buffer -b keepalive - 2>/dev/null || return 1
  tmux paste-buffer -d -p -b keepalive -t "$pane" 2>/dev/null || return 1
  tmux send-keys -t "$pane" Enter 2>/dev/null
}

# Un collage bracketé est remis au hook enveloppé par Claude Code, sous la forme
# "\n\n<pasted_content id=\"…\">\n<le texte>". La signature [keepalive] n'est
# donc plus en tête du prompt : on déballe avant de la chercher.
unwrap_prompt() {
  local p=$1
  p=${p#"${p%%[![:space:]]*}"}
  case "$p" in
    "<pasted_content"*) p=${p#*>}; p=${p#"${p%%[![:space:]]*}"} ;;
  esac
  printf '%s' "$p"
}
