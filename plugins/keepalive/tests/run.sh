#!/usr/bin/env bash
# Suite de tests du plugin keepalive.
# tmux est remplacé par un stub : aucun pane réel, aucun appel réseau, aucun coût.
#   bash plugins/keepalive/tests/run.sh

SCR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export KEEPALIVE_STATE_DIR="$TMP/state"   # jamais l'état des sessions réelles
STATE="$KEEPALIVE_STATE_DIR"
PING="ping keepalive — réponds uniquement OK"

# ── stub tmux : capture-pane sert un pane simulé, le reste est journalisé
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "capture-pane" ]; then cat "${TMUX_STUB_PANE:-/dev/null}"; exit 0; fi
echo "$@" >> "${TMUX_STUB_LOG:-/dev/null}"
STUB
chmod +x "$TMP/bin/tmux"
printf '\xe2\x9d\xaf \n'                                        > "$TMP/pane_idle"    # boîte vide
printf '\xe2\x9d\xaf un brouillon non envoye\n'                 > "$TMP/pane_draft"   # brouillon
printf ' Do you want to proceed?\n \xe2\x9d\xaf 1. Yes\n   2. No\n' > "$TMP/pane_dialog" # permission
:                                                               > "$TMP/pane_blank"   # illisible

export PATH="$TMP/bin:$PATH" TMUX_PANE="%99" TMUX_STUB_LOG="$TMP/tmux.log"
export TMUX_STUB_PANE="$TMP/pane_idle" KEEPALIVE_DELAY=2

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "  ✅ $1"; pass=$((pass+1));
      else echo "  ❌ $1 (attendu='$3' obtenu='$2')"; fail=$((fail+1)); fi; }
run(){ jq -nc --arg s "$3" --arg e "$1" --arg p "$2" \
       '{session_id:$s,hook_event_name:$e,prompt:$p}' | bash "$SCR/keepalive.sh"; }
end(){ jq -nc --arg s "$1" '{session_id:$s,hook_event_name:"SessionEnd"}' | bash "$SCR/cleanup.sh"; }
pings(){ grep -c 'send-keys' "$TMUX_STUB_LOG" 2>/dev/null | tr -d ' '; }
armed(){ [ -f "$STATE/$1.pid" ] && echo oui || echo non; }
clean(){ for f in "$STATE"/*.pid; do [ -f "$f" ] || continue
           P=$(cat "$f"); pkill -P "$P" 2>/dev/null; kill "$P" 2>/dev/null; done
         rm -f "$STATE"/*.pid "$STATE"/*.count; sleep 0.2
         : > "$TMUX_STUB_LOG"; TMUX_STUB_PANE="$TMP/pane_idle"; }

echo "── Conditions d'activation"
S=t1-$$; clean
jq -nc --arg s "$S" '{session_id:$s,hook_event_name:"Stop"}' | env -u TMUX_PANE bash "$SCR/keepalive.sh"
ok "hors tmux : pas de timer" "$(armed $S)" "non"
S=t2-$$; clean
jq -nc --arg s "$S" '{session_id:$s,hook_event_name:"Stop"}' | KEEPALIVE_DISABLE=1 bash "$SCR/keepalive.sh"
ok "KEEPALIVE_DISABLE=1 : pas de timer" "$(armed $S)" "non"

echo "── Timer et debounce"
S=t3-$$; clean; run Stop "" $S
ok "Stop arme un timer" "$(armed $S)" "oui"
sleep 3
ok "un ping est parti" "$(pings)" "1"
ok "contenu du ping" "$(cat "$TMUX_STUB_LOG")" "send-keys -t %99 $PING Enter"
S=t4-$$; clean; run Stop "" $S; sleep 0.5; run Stop "" $S; sleep 0.5; run Stop "" $S; sleep 3
ok "3 hooks rapprochés => 1 seul ping" "$(pings)" "1"

echo "── Compteur et plafond"
S=t5-$$; clean
run UserPromptSubmit "$PING" $S; ok "un ping incrémente" "$(cat "$STATE/$S.count")" "1"
run UserPromptSubmit "$PING" $S; ok "puis incrémente encore" "$(cat "$STATE/$S.count")" "2"
run UserPromptSubmit "salut"  $S; ok "un prompt humain remet à zéro" "$(cat "$STATE/$S.count")" "0"
# Un subagent qui se termine réinjecte un UserPromptSubmit : il ne doit pas
# compter comme un retour humain.
S=t5b-$$; clean; echo 4 > "$STATE/$S.count"
NOTIF='<task-notification>
<task-id>abc</task-id>
<status>completed</status>
</task-notification>'
run UserPromptSubmit "$NOTIF" $S
ok "fin de subagent : compteur inchangé" "$(cat "$STATE/$S.count")" "4"
ok "fin de subagent : timer quand même relancé" "$(armed $S)" "oui"
S=t6-$$; clean; mkdir -p "$STATE"; echo 3 > "$STATE/$S.count"
KEEPALIVE_MAX_PINGS=3 run Stop "" $S
ok "plafond atteint : pas de timer" "$(armed $S)" "non"
sleep 3; ok "plafond atteint : pas de ping" "$(pings)" "0"

echo "── Nettoyage de fin de session"
S=t7-$$; clean; run Stop "" $S; end $S
ok "état purgé" "$(ls "$STATE" 2>/dev/null | grep -c "^$S" | tr -d ' ')" "0"
sleep 3; ok "plus de ping après SessionEnd" "$(pings)" "0"

echo "── Pas de fuite de processus"
S=t8-$$; clean
base=$(pgrep -f 'sleep 600' | wc -l | tr -d ' ')
for i in 1 2 3 4 5; do KEEPALIVE_DELAY=600 run Stop "" $S; done; sleep 0.4
ok "5 hooks => 1 seul sleep vivant" "$(( $(pgrep -f 'sleep 600' | wc -l | tr -d ' ') - base ))" "1"
end $S; sleep 0.4
ok "SessionEnd => aucun sleep restant" "$(( $(pgrep -f 'sleep 600' | wc -l | tr -d ' ') - base ))" "0"

echo "── Garde du pane : où le ping a le droit d'atterrir"
S=t9-$$;  clean; TMUX_STUB_PANE="$TMP/pane_draft";  run Stop "" $S; sleep 3
ok "brouillon en cours : pas de ping" "$(pings)" "0"
S=t10-$$; clean; TMUX_STUB_PANE="$TMP/pane_dialog"; run Stop "" $S; sleep 3
ok "dialogue de permission ouvert : pas de ping" "$(pings)" "0"
S=t11-$$; clean; TMUX_STUB_PANE="$TMP/pane_blank";  run Stop "" $S; sleep 3
ok "pane illisible : pas de ping" "$(pings)" "0"
S=t12-$$; clean; run Stop "" $S; sleep 3
ok "pane au repos : ping envoyé" "$(pings)" "1"

echo "── Sans plafond (défaut)"
S=t14-$$; clean; mkdir -p "$STATE"; echo 999 > "$STATE/$S.count"
run Stop "" $S
ok "par défaut : timer armé malgré 999 pings déjà envoyés" "$(armed $S)" "oui"
sleep 3; ok "par défaut : ping envoyé quand même" "$(pings)" "1"
S=t14b-$$; clean; mkdir -p "$STATE"; echo 99 > "$STATE/$S.count"
KEEPALIVE_MAX_PINGS=0 run Stop "" $S
ok "MAX=0 explicite : timer armé" "$(armed $S)" "oui"

echo "── Valeurs de config invalides"
S=t15-$$; clean; KEEPALIVE_MAX_PINGS=abc run Stop "" $S
ok "MAX non numérique : retombe sur le défaut (sans plafond)" "$(armed $S)" "oui"
S=t16-$$; clean; KEEPALIVE_DELAY=abc run Stop "" $S; sleep 3
ok "DELAY non numérique : pas de ping immédiat parasite" "$(pings)" "0"
ok "DELAY non numérique : timer quand même armé" "$(armed $S)" "oui"
clean

echo "── Garde anti-réutilisation de PID"
S=t13-$$; clean; mkdir -p "$STATE"
sleep 300 & victime=$!; echo $victime > "$STATE/$S.pid"   # .pid périmé pointant un tiers
run Stop "" $S
ok "process tiers épargné" "$(kill -0 $victime 2>/dev/null && echo vivant || echo tué)" "vivant"
kill $victime 2>/dev/null; clean

echo; echo "════ $pass réussis, $fail échoués ════"
[ "$fail" -eq 0 ]
