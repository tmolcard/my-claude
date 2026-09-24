---
name: keepalive
description: Piloter le keepalive de cette session (on, off, status, now, delay, prompt, stats, max, reset).
argument-hint: "[status|on|off|now|delay 30m|prompt <texte>|stats on|off|max N|reset]"
disable-model-invocation: true
---

Cette commande est normalement interceptée par le hook du plugin keepalive avant de
t'atteindre. Si tu lis ce texte, le hook n'est pas actif dans cette session.

Dis-le à l'utilisateur en une ou deux lignes, sans rien exécuter d'autre. Causes
probables : la session a été lancée avant l'installation ou la mise à jour du plugin
(relancer `claude --continue`), ou `jq` est absent de la machine.
