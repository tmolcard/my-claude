# my-claude

Configuration Claude Code perso, distribuée sous forme de marketplace de plugins.

## Installation

```bash
claude plugin marketplace add tmolcard/my-claude
claude plugin install keepalive@my-claude
```

Mise à jour : `claude plugin marketplace update my-claude` puis `claude plugin update keepalive@my-claude`.

## Plugins

### keepalive

Maintient le cache prompt (TTL 1 h) d'une session interactive : si aucune activité pendant
55 min, un ping est injecté dans le pane tmux de la session, ce qui rafraîchit le cache
au prix d'un cache read plutôt qu'une réécriture complète à la reprise.

Fonctionnement : les hooks `Stop` et `UserPromptSubmit` relancent un timer (debounce) ;
`SessionEnd` le tue. Aucun daemon, aucun polling.

Prérequis : `tmux` (la session Claude doit tourner dans un pane tmux) et `jq`.
Hors tmux, le plugin ne fait rien.

Variables d'environnement :

| Variable              | Défaut | Rôle                                                        |
|-----------------------|--------|-------------------------------------------------------------|
| `KEEPALIVE_DELAY`     | 3300   | Secondes d'inactivité avant ping                            |
| `KEEPALIVE_MAX_PINGS` | 12     | Pings consécutifs sans activité humaine avant abandon       |
| `KEEPALIVE_DISABLE`   | 0      | `1` pour désactiver sans désinstaller                       |

Rentabilité : un ping coûte ~0,1× le contexte par heure ; une réécriture de cache 1 h coûte ~2×
une fois. Au-delà de ~15–20 h d'inactivité continue, laisser expirer est moins cher —
d'où le plafond `KEEPALIVE_MAX_PINGS`.
