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

Ça tourne en boucle indéfiniment, tant que la session vit. Chaque ping réarme le timer
suivant : tu fermes la session quand tu veux, le plugin ne décide jamais d'arrêter à ta place.

Une seule chose à savoir : **une session déjà ouverte ne le prend pas.** Les hooks sont lus
au démarrage, donc il faut relancer `claude` (`claude --continue` reprend la conversation).

### Régler

Variables d'environnement, à exporter avant de lancer `claude` :

| Variable              | Défaut | Rôle                                                  |
|-----------------------|--------|-------------------------------------------------------|
| `KEEPALIVE_DELAY`     | 3300   | Secondes d'inactivité avant le ping (3300 = 55 min)   |
| `KEEPALIVE_MAX_PINGS` | 0      | `0` = sans limite. Un nombre = s'arrête après N pings d'affilée |
| `KEEPALIVE_DISABLE`   | 0      | `1` pour désactiver sans désinstaller                  |

```bash
export KEEPALIVE_DELAY=1800     # ping après 30 min au lieu de 55
export KEEPALIVE_MAX_PINGS=12   # si tu veux quand même un frein (~11 h)
claude
```

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
bash plugins/keepalive/tests/run.sh   # 28 tests, tmux simulé, aucun coût
```

Après toute modification, bumper la version dans `plugins/keepalive/.claude-plugin/plugin.json`
**et** `.claude-plugin/marketplace.json` : `claude plugin update` est piloté par la version et
ne fait rien sans bump.

Mise à jour côté utilisateur : `claude plugin marketplace update my-claude` puis
`claude plugin update keepalive@my-claude`.
