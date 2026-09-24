#!/usr/bin/env bash
# Suite de tests du plugin keepalive.
# tmux est remplacé par un stub : aucun pane réel, aucun appel réseau, aucun coût.
#   bash plugins/keepalive/tests/run.sh

SCR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export KEEPALIVE_STATE_DIR="$TMP/state"   # jamais l'état des sessions réelles
STATE="$KEEPALIVE_STATE_DIR"
PREFIX="[keepalive]"

# ── stub tmux : capture-pane sert un pane simulé, le reste est journalisé
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "capture-pane" ]; then cat "${TMUX_STUB_PANE:-/dev/null}"; exit 0; fi
# load-buffer lit le texte sur stdin, paste-buffer le dépose dans le pane :
# on journalise au collage, une ligne par ping.
if [ "$1" = "load-buffer" ];  then cat > "${TMUX_STUB_LOG%.log}.buf"; exit 0; fi
if [ "$1" = "paste-buffer" ]; then { cat "${TMUX_STUB_LOG%.log}.buf"; echo; } >> "${TMUX_STUB_LOG:-/dev/null}"; exit 0; fi
STUB
chmod +x "$TMP/bin/tmux"
printf '\xe2\x9d\xaf \n'                                        > "$TMP/pane_idle"    # boîte vide
printf '\xe2\x9d\xaf un brouillon non envoye\n'                 > "$TMP/pane_draft"   # brouillon
printf ' Do you want to proceed?\n \xe2\x9d\xaf 1. Yes\n   2. No\n' > "$TMP/pane_dialog" # permission
:                                                               > "$TMP/pane_blank"   # illisible
# Formes réelles relevées avec capture-pane -e : chevron suivi d'une espace
# insécable, suggestion de prompt en faible intensité (SGR 2).
printf '\033[39m\xe2\x9d\xaf\xc2\xa0\033[0m\n'                            > "$TMP/pane_nbsp"
printf '\033[39m\xe2\x9d\xaf\xc2\xa0\033[2mOu en est le training ?\033[0m\n' > "$TMP/pane_suggest"
printf '\033[39m\xe2\x9d\xaf\xc2\xa0un vrai brouillon\033[0m\n'           > "$TMP/pane_draft_c"
printf ' \033[36m\xe2\x9d\xaf\033[0m \033[2m1. Yes\033[0m\n'                > "$TMP/pane_dialog_dim"

export PATH="$TMP/bin:$PATH" TMUX_PANE="%99" TMUX_STUB_LOG="$TMP/tmux.log"
export TMUX_STUB_PANE="$TMP/pane_idle" KEEPALIVE_DELAY=2
export TMUX_STUB_LOG="$TMP/tmux.log"

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then echo "  ✅ $1"; pass=$((pass+1));
      else echo "  ❌ $1 (attendu='$3' obtenu='$2')"; fail=$((fail+1)); fi; }
run(){ jq -nc --arg s "$3" --arg e "$1" --arg p "$2" \
       '{session_id:$s,hook_event_name:$e,prompt:$p}' | bash "$SCR/keepalive.sh"; }
end(){ jq -nc --arg s "$1" '{session_id:$s,hook_event_name:"SessionEnd"}' | bash "$SCR/cleanup.sh"; }
pings(){ grep -c '\[keepalive\]' "$TMUX_STUB_LOG" 2>/dev/null | tr -d ' '; }
armed(){ [ -f "$STATE/$1.pid" ] && echo oui || echo non; }
clean(){ for f in "$STATE"/*.pid; do [ -f "$f" ] || continue
           P=$(cat "$f"); pkill -P "$P" 2>/dev/null; kill "$P" 2>/dev/null; done
         rm -f "$STATE"/*; sleep 0.2
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
ok "le ping porte le préfixe de signature" "$(cut -c1-11 "$TMUX_STUB_LOG")" "$PREFIX"
ok "le ping tient sur une seule ligne" "$(wc -l < "$TMUX_STUB_LOG" | tr -d ' ')" "1"
S=t4-$$; clean; run Stop "" $S; sleep 0.5; run Stop "" $S; sleep 0.5; run Stop "" $S; sleep 3
ok "3 hooks rapprochés => 1 seul ping" "$(pings)" "1"

echo "── Compteur et plafond"
S=t5-$$; clean
run UserPromptSubmit "$PREFIX blabla" $S; ok "un ping incrémente" "$(cat "$STATE/$S.count")" "1"
run UserPromptSubmit "$PREFIX autre"  $S; ok "puis incrémente encore" "$(cat "$STATE/$S.count")" "2"
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
S=t12b-$$; clean; TMUX_STUB_PANE="$TMP/pane_nbsp";    run Stop "" $S; sleep 3
ok "boîte vide avec espace insécable (Linux) : ping envoyé" "$(pings)" "1"
S=t12c-$$; clean; TMUX_STUB_PANE="$TMP/pane_suggest"; run Stop "" $S; sleep 3
ok "suggestion de prompt grisée : ping envoyé" "$(pings)" "1"
S=t12d-$$; clean; TMUX_STUB_PANE="$TMP/pane_draft_c"; run Stop "" $S; sleep 3
ok "brouillon en couleur normale : pas de ping" "$(pings)" "0"
S=t12e-$$; clean; TMUX_STUB_PANE="$TMP/pane_dialog_dim"; run Stop "" $S; sleep 3
ok "dialogue indenté, même grisé : pas de ping" "$(pings)" "0"

echo "── Sans plafond (défaut)"
S=t14-$$; clean; mkdir -p "$STATE"; echo 999 > "$STATE/$S.count"
run Stop "" $S
ok "par défaut : timer armé malgré 999 pings déjà envoyés" "$(armed $S)" "oui"
sleep 3; ok "par défaut : ping envoyé quand même" "$(pings)" "1"
S=t14b-$$; clean; mkdir -p "$STATE"; echo 99 > "$STATE/$S.count"
KEEPALIVE_MAX_PINGS=0 run Stop "" $S
ok "MAX=0 explicite : timer armé" "$(armed $S)" "oui"

echo "── Prompt de ping personnalisé"
S=t17-$$; clean; KEEPALIVE_STATS=0 KEEPALIVE_PROMPT="coucou le cache" run Stop "" $S; sleep 3
ok "le préfixe est ajouté d'office s'il manque" "$(cat "$TMUX_STUB_LOG")" "$PREFIX coucou le cache"
S=t18-$$; clean; KEEPALIVE_STATS=0 KEEPALIVE_PROMPT="$PREFIX déjà préfixé" run Stop "" $S; sleep 3
ok "un préfixe déjà présent n'est pas doublé" "$(cat "$TMUX_STUB_LOG")" "$PREFIX déjà préfixé"
S=t19-$$; clean; KEEPALIVE_STATS=0 KEEPALIVE_PROMPT="deux
lignes" run Stop "" $S; sleep 3
ok "retour à la ligne aplati (pas de validation à mi-chemin)" "$(cat "$TMUX_STUB_LOG")" "$PREFIX deux lignes"

echo "── Instantané des ressources joint au ping"
S=t20-$$; clean; KEEPALIVE_PROMPT="court" run Stop "" $S; sleep 3
ok "les ressources sont jointes par défaut" "$(grep -c 'Ressources machine' "$TMUX_STUB_LOG")" "1"
ok "et restent sur une seule ligne" "$(wc -l < "$TMUX_STUB_LOG" | tr -d ' ')" "1"
S=t21-$$; clean; KEEPALIVE_STATS=0 KEEPALIVE_PROMPT="court" run Stop "" $S; sleep 3
ok "KEEPALIVE_STATS=0 les omet" "$(grep -c 'Ressources machine' "$TMUX_STUB_LOG")" "0"

echo "── Valeurs de config invalides"
S=t15-$$; clean; KEEPALIVE_MAX_PINGS=abc run Stop "" $S
ok "MAX non numérique : retombe sur le défaut (sans plafond)" "$(armed $S)" "oui"
S=t16-$$; clean; KEEPALIVE_DELAY=abc run Stop "" $S; sleep 3
ok "DELAY non numérique : pas de ping immédiat parasite" "$(pings)" "0"
ok "DELAY non numérique : timer quand même armé" "$(armed $S)" "oui"
clean

echo "── Prompt livré en collage bracketé"
S=t22-$$; clean; echo 5 > "$STATE/$S.count"
# Claude Code enveloppe un collage avant de le passer au hook : la signature
# n'est plus en tête, le compteur doit quand même la retrouver.
WRAPPED=$(printf '\n\n<pasted_content id="951b">\n%s ping' "$PREFIX")
run UserPromptSubmit "$WRAPPED" $S
ok "signature retrouvée sous l'enveloppe <pasted_content>" "$(cat "$STATE/$S.count")" "6"
S=t23-$$; clean; echo 5 > "$STATE/$S.count"
HUMAN=$(printf '\n\n<pasted_content id="7c2a">\nvoici mon fichier collé')
run UserPromptSubmit "$HUMAN" $S
ok "un vrai collage humain remet bien à zéro" "$(cat "$STATE/$S.count")" "0"

echo "── Commande /keepalive, mode silencieux (KEEPALIVE_QUIET=1 : bloquée, jamais transmise au modèle)"
export KEEPALIVE_QUIET=1
cmd(){ run UserPromptSubmit "/keepalive $1" "${2:-$S}"; }
reason(){ jq -r '.reason // empty'; }
S=c1-$$; clean; mkdir -p "$STATE"; echo 4 > "$STATE/$S.count"
OUT=$(cmd status)
ok "status : prompt bloqué" "$(jq -r .decision <<<"$OUT")" "block"
ok "status : décrit l'état" "$(reason <<<"$OUT" | grep -c '^keepalive : ')" "1"
ok "une commande ne touche pas au compteur" "$(cat "$STATE/$S.count")" "4"
ok "une commande n'arme pas de timer" "$(armed $S)" "non"
OUT=$(run UserPromptSubmit "/keepalive:keepalive status" $S)
ok "forme longue /keepalive:keepalive reconnue" "$(jq -r .decision <<<"$OUT")" "block"
OUT=$(run UserPromptSubmit "/keepalivex" $S)
ok "/keepalivex n'est pas notre commande" "$OUT" ""
ok "… et compte comme message humain" "$(cat "$STATE/$S.count")" "0"
OUT=$(cmd blabla)
ok "sous-commande inconnue signalée" "$(reason <<<"$OUT" | grep -c inconnue)" "1"
OUT=$(jq -nc --arg s "$S" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/keepalive"}' | env -u TMUX_PANE bash "$SCR/keepalive.sh")
ok "hors tmux : la commande répond quand même" "$(reason <<<"$OUT" | grep -c 'pas dans tmux')" "1"

S=c2-$$; clean; run Stop "" $S; cmd off >/dev/null
ok "off : timer tué" "$(armed $S)" "non"
sleep 3; ok "off : aucun ping" "$(pings)" "0"
run Stop "" $S; ok "off : l'activité suivante ne réarme pas" "$(armed $S)" "non"
ok "off : status le dit" "$(cmd status | reason | grep -c 'coupé')" "1"
end $S; ok "off survit à SessionEnd (--resume garde l'id)" "$([ -f "$STATE/$S.off" ] && echo oui || echo non)" "oui"
run Stop "" $S; ok "… et reste coupé après reprise" "$(armed $S)" "non"
echo 3 > "$STATE/$S.count"; cmd on >/dev/null
ok "on : timer réarmé" "$(armed $S)" "oui"
ok "on : compteur remis à zéro" "$(cat "$STATE/$S.count")" "0"
sleep 3.5; ok "on : le ping repart" "$(pings)" "1"

S=c3-$$; clean; KEEPALIVE_DELAY=600 run Stop "" $S
KEEPALIVE_DELAY=600 cmd now >/dev/null; sleep 4
ok "now : ping immédiat malgré un délai de 10 min" "$(pings)" "1"
S=c3b-$$; clean; KEEPALIVE_DELAY=600 run Stop "" $S; cmd off >/dev/null; cmd now >/dev/null; sleep 4
ok "now refusé quand coupé" "$(pings)" "0"

S=c4-$$; clean; KEEPALIVE_DELAY=600 run Stop "" $S
KEEPALIVE_DELAY=600 cmd "delay 30m" >/dev/null
ok "delay 30m enregistré en secondes" "$(cat "$STATE/$S.delay")" "1800"
KEEPALIVE_DELAY=600 cmd "delay 1h30" >/dev/null; ok "delay 1h30" "$(cat "$STATE/$S.delay")" "5400"
OUT=$(KEEPALIVE_DELAY=600 cmd "delay 1h30"); ok "délai > 1 h : avertissement TTL" "$(reason <<<"$OUT" | grep -c 'aura expiré')" "1"
OUT=$(cmd "delay abc"); ok "durée invalide refusée" "$(reason <<<"$OUT" | grep -c 'non comprise')" "1"
ok "… sans écraser le réglage" "$(cat "$STATE/$S.delay")" "5400"
KEEPALIVE_DELAY=600 cmd "delay 10s" >/dev/null
due=$(( $(cat "$STATE/$S.due") - $(date +%s) ))
ok "delay réarme calé sur la dernière activité" "$([ "$due" -le 10 ] && echo oui || echo non)" "oui"
sleep 11; ok "… et le ping part à la nouvelle échéance" "$(pings)" "1"
cmd "delay reset" >/dev/null; ok "delay reset" "$([ -f "$STATE/$S.delay" ] && echo oui || echo non)" "non"

S=c5-$$; clean; KEEPALIVE_STATS=0 run Stop "" $S; KEEPALIVE_STATS=0 cmd "prompt coucou session" >/dev/null; sleep 3
ok "prompt de session appliqué au ping déjà armé" "$(cat "$TMUX_STUB_LOG")" "$PREFIX coucou session"
S=c6-$$; clean; KEEPALIVE_PROMPT=court run Stop "" $S; cmd "stats off" >/dev/null; sleep 3
ok "stats off appliqué au ping déjà armé" "$(grep -c 'Ressources machine' "$TMUX_STUB_LOG")" "0"
S=c7-$$; clean; mkdir -p "$STATE"; echo 2 > "$STATE/$S.count"; run Stop "" $S; cmd "max 2" >/dev/null
ok "max 2 avec 2 pings déjà faits : timer coupé" "$(armed $S)" "non"
ok "… et status explique la pause" "$(cmd status | reason | grep -c 'plafond de 2')" "1"
cmd "max 0" >/dev/null; ok "max 0 : sans limite, réarmé" "$(armed $S)" "oui"
cmd off >/dev/null; cmd "delay 5m" >/dev/null; cmd reset >/dev/null
ok "reset efface les réglages de session" "$(ls "$STATE" | grep -cE "^$S\.(off|delay|max)$")" "0"
ok "reset réarme" "$(armed $S)" "oui"
clean
unset KEEPALIVE_QUIET

echo "── Commande /keepalive, mode visible (défaut : résultat transmis au modèle, visible dans l'app)"
ctx(){ jq -r '.hookSpecificOutput.additionalContext // empty'; }
S=v1-$$; clean; mkdir -p "$STATE"; echo 4 > "$STATE/$S.count"
OUT=$(cmd status)
ok "status : le prompt n'est pas bloqué" "$(jq -r '.decision // "passe"' <<<"$OUT")" "passe"
ok "status : résultat en contexte additionnel" "$(ctx <<<"$OUT" | head -1 | cut -c1-37)" "[keepalive-résultat] **keepalive** · "
ok "status : annonce l'échéance après la réponse" "$(ctx <<<"$OUT" | grep -c 'après cette réponse')" "1"
ok "compteur inchangé" "$(cat "$STATE/$S.count")" "4"
OUT=$(cmd off); ok "off : confirmé en contexte" "$(ctx <<<"$OUT" | grep -c 'coupé')" "1"
ok "off : appliqué par le hook" "$([ -f "$STATE/$S.off" ] && echo oui || echo non)" "oui"
run Stop "" $S; ok "off : la fin du tour de réponse ne réarme pas" "$(armed $S)" "non"
S=v2-$$; clean; KEEPALIVE_DELAY=600 run Stop "" $S
OUT=$(KEEPALIVE_DELAY=600 cmd now)
ok "now : annoncé après la réponse" "$(ctx <<<"$OUT" | grep -c 'après cette réponse')" "1"
sleep 4; ok "now : rien pendant la réponse du modèle" "$(pings)" "0"
KEEPALIVE_DELAY=600 run Stop "" $S; sleep 4
ok "now : ping 3 s après la fin du tour" "$(pings)" "1"
ok "now : marqueur consommé" "$([ -f "$STATE/$S.now" ] && echo oui || echo non)" "non"
KEEPALIVE_DELAY=600 run Stop "" $S
due=$(( $(cat "$STATE/$S.due") - $(date +%s) ))
ok "tour suivant : retour au délai normal" "$([ "$due" -gt 500 ] && echo oui || echo non)" "oui"
clean

echo "── Sécurité de l'état"
S=s1-$$; clean
mkdir -p "$TMP/ailleurs"; ln -s "$TMP/ailleurs" "$TMP/lien"
jq -nc --arg s "$S" '{session_id:$s,hook_event_name:"Stop"}' | KEEPALIVE_STATE_DIR="$TMP/lien" bash "$SCR/keepalive.sh"
ok "répertoire d'état en lien symbolique : refusé" "$(ls "$TMP/ailleurs" | wc -l | tr -d ' ')" "0"
run Stop "" "../evasion"
ok "session_id avec ../ : refusé" "$([ -e "$TMP/evasion.pid" ] && echo écrit || echo refusé)" "refusé"
S=s2-$$; clean; mkdir -p "$STATE"
printf 'a[$(touch %s)]' "$TMP/pwned" > "$STATE/$S.count"
run UserPromptSubmit "$PREFIX ping" $S
ok "compteur piégé : pas d'exécution de code" "$([ -e "$TMP/pwned" ] && echo exécuté || echo inerte)" "inerte"
ok "… et repart de 0" "$(cat "$STATE/$S.count")" "1"
clean

echo "── Garde anti-réutilisation de PID"
S=t13-$$; clean; mkdir -p "$STATE"
sleep 300 & victime=$!; echo $victime > "$STATE/$S.pid"   # .pid périmé pointant un tiers
run Stop "" $S
ok "process tiers épargné" "$(kill -0 $victime 2>/dev/null && echo vivant || echo tué)" "vivant"
kill $victime 2>/dev/null; clean

echo; echo "════ $pass réussis, $fail échoués ════"
[ "$fail" -eq 0 ]
