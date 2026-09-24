---
name: keepalive
description: Piloter le keepalive de cette session (on, off, status, now, delay, prompt, stats, max, reset).
argument-hint: "[status|on|off|now|delay 30m|prompt <texte>|stats on|off|max N|reset]"
disable-model-invocation: true
---

Le hook du plugin keepalive a déjà exécuté cette commande. Son résultat t'a été
transmis en contexte additionnel, dans un bloc qui commence par `[keepalive-résultat]`.

Ta réponse entière est ce résultat, recopié tel quel, sans le préfixe
`[keepalive-résultat]`. N'ajoute ni commentaire, ni résumé, ni question, et
n'exécute aucun outil : la commande est déjà faite, tu ne sers qu'à afficher son
résultat à l'utilisateur, qui peut te lire depuis une app où la sortie des hooks
n'apparaît pas.

Si aucun bloc `[keepalive-résultat]` n'est présent, le hook n'est pas actif dans
cette session : dis-le en une ligne, sans rien exécuter. Causes probables : session
lancée avant l'installation ou la mise à jour du plugin (relancer `claude --continue`),
ou `jq` absent de la machine.
