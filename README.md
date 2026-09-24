# my-claude

Ma config Claude Code, distribuée comme marketplace de plugins.

## keepalive

Garde le cache prompt au chaud. Si tu ne touches à rien pendant 55 min, un « ping » part
tout seul dans ta session : le cache (TTL 1 h) est rafraîchi au prix d'un cache read, au
lieu d'être réécrit entièrement à ton retour.

### Installer

```bash
claude plugin marketplace add tmolcard/my-claude
claude plugin install keepalive@my-claude
```

Il faut `tmux` et `jq`, et ta session Claude doit tourner dans un pane tmux :

```bash
tmux new -s dev
claude
```

Hors tmux, le plugin ne fait rien du tout (silencieusement, pas d'erreur).

### Utiliser

Rien à faire : toute nouvelle session lancée dans tmux est prise en charge.

Ça ne s'arme que sur ta session principale : les subagents n'ont pas de timer à eux. Quand
un subagent lancé en arrière-plan se termine, son résultat revient dans ta session comme un
prompt, ce qui relance le timer normalement.

Ça tourne en boucle indéfiniment, tant que la session vit. Chaque ping réarme le timer
suivant : tu fermes la session quand tu veux, le plugin ne décide jamais d'arrêter à ta place.

Une seule chose à savoir : **une session déjà ouverte ne le prend pas.** Les hooks sont lus
au démarrage, donc il faut relancer `claude` (`claude --continue` reprend la conversation).

### Piloter une session en cours : `/keepalive`

Tape la commande dans la session elle-même. Elle est traitée par le plugin et n'est jamais
envoyée au modèle : aucun token dépensé.

| Commande                          | Effet                                                        |
|-----------------------------------|--------------------------------------------------------------|
| `/keepalive`                      | État : actif ou coupé, prochain ping, réglages               |
| `/keepalive off` / `on`           | Coupe les pings de cette session / les relance               |
| `/keepalive now`                  | Envoie un ping tout de suite                                 |
| `/keepalive delay 30m`            | Change le délai (`90s`, `30m`, `1h30`) ; `delay reset` revient au défaut |
| `/keepalive prompt <texte>`       | Change le texte du ping ; `prompt reset` remet le prompt de mission |
| `/keepalive stats on`/`off`       | Joint ou non le relevé machine                               |
| `/keepalive max 12`               | Plafond de pings d'affilée (`0` = sans limite)               |
| `/keepalive reset`                | Efface tous les réglages de la session                       |

Ces réglages ne valent que pour la session où tu les tapes, et priment sur les variables
d'environnement ci-dessous. Ils survivent à `claude --resume` : une session coupée reste
coupée après un redémarrage.

Un changement de délai compte depuis ta dernière activité : passer à 30 min après 40 min de
silence déclenche le ping tout de suite.

### Régler par défaut

Variables d'environnement, à exporter avant de lancer `claude` :

| Variable              | Défaut | Rôle                                                  |
|-----------------------|--------|-------------------------------------------------------|
| `KEEPALIVE_DELAY`     | 3300   | Secondes d'inactivité avant le ping (3300 = 55 min)   |
| `KEEPALIVE_MAX_PINGS` | 0      | `0` = sans limite. Un nombre = s'arrête après N pings d'affilée |
| `KEEPALIVE_PROMPT`    | voir ci-dessous | Le texte envoyé comme ping                   |
| `KEEPALIVE_STATS`     | 1      | Joint un relevé CPU/RAM/disque/GPU au ping ; `0` l'omet |
| `KEEPALIVE_DISABLE`   | 0      | `1` pour désactiver sans désinstaller                  |

```bash
export KEEPALIVE_DELAY=1800     # ping après 30 min au lieu de 55
export KEEPALIVE_MAX_PINGS=12   # si tu veux quand même un frein (~11 h)
export KEEPALIVE_PROMPT="continue ce sur quoi tu travaillais"
claude
```

Le ping par défaut ne se contente pas de repousser le TTL : il demande à Claude de relire la
mission de la session, de vérifier que les runs lancées tournent toujours, et — si la mission
l'y autorise explicitement — d'enchaîner la run suivante en justifiant son choix. Il s'arrête
de lui-même quand le budget ou le critère d'arrêt est atteint, ou après deux échecs
consécutifs de même cause.

`KEEPALIVE_PROMPT` le remplace par ce que tu veux. Le préfixe `[keepalive]` est ajouté d'office
s'il manque : c'est à lui que le hook reconnaît ses propres pings, et ne pas le perdre est ce
qui permet au compteur de rester juste.

Chaque ping est complété d'un relevé pris à cet instant précis — charge CPU, RAM, disque, et
sur machine NVIDIA le nombre de cartes libres et la VRAM. C'est ce qui permet de répondre
« les ressources sont libres, j'enchaîne » sans deviner. `KEEPALIVE_STATS=0` le retire.

Le compteur de pings repart à zéro dès que **tu** envoies un vrai message. Les prompts
injectés par le système — typiquement la fin d'un subagent lancé en arrière-plan, que Claude
Code réinjecte dans la session — relancent bien le timer (ce tour rafraîchit vraiment le
cache) mais ne remettent pas le compteur à zéro : personne n'est revenu devant le clavier.

### Quand il refuse de pinger (c'est voulu)

Le ping n'est envoyé que si ta boîte de saisie est vide. S'il y reste un brouillon non
envoyé, ou si un dialogue de permission est ouvert, le plugin s'abstient : sinon il
écraserait ton texte, ou répondrait à ta place au dialogue (`Enter` = « 1. Yes »).
En cas de doute il ne fait rien — au pire le cache expire, ça ne coûte qu'une réécriture.

### Développer

```bash
bash plugins/keepalive/tests/run.sh   # 76 tests, tmux simulé, aucun coût
```

Après toute modification, bumper la version dans `plugins/keepalive/.claude-plugin/plugin.json`
**et** `.claude-plugin/marketplace.json` : `claude plugin update` est piloté par la version et
ne fait rien sans bump.

Mise à jour côté utilisateur : `claude plugin marketplace update my-claude` puis
`claude plugin update keepalive@my-claude`.
