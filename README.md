# claude-morning-reset

Sort l'ordinateur de veille le matin, envoie un message à Claude Code pour démarrer la fenêtre d'utilisation, et **affiche une alerte quand la session Claude a expiré**.

Fonctionne sur **macOS**, **Linux** (systemd) et **Windows**.

## Ce que ça fait

| Moment | Action |
|---|---|
| 2 min avant l'heure choisie | L'ordi sort de veille (optionnel) |
| À l'heure choisie, les jours choisis | `claude -p "<message>"`, avec 3 essais si le réseau n'est pas prêt |
| Le reset échoue (session expirée) | Fenêtre d'alerte qui reste affichée jusqu'à ce que tu la fermes, donc visible en ouvrant l'ordi |
| Ouverture de session, réveil, déverrouillage | Vérifie que Claude Code est toujours connecté, sinon alerte |
| Connexion qui expire dans moins de 7 jours | Alerte préventive (une fois par jour) |

Sur macOS et Windows, l'alerte propose un bouton **Se reconnecter** qui ouvre un terminal avec `claude auth login`.

## Installation

Prérequis : [Claude Code](https://claude.com/claude-code) installé et connecté (`claude auth login`).

### macOS / Linux

```bash
./install.sh
```

Le script détecte le système, pose les questions (heure, récurrence, réveil) et installe tout. Sans questions :

```bash
./install.sh --time 07:30 --days weekdays --wake
```

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Time 07:30 -Days weekdays
```

### Options

| macOS / Linux | Windows | Rôle |
|---|---|---|
| `--time HH:MM` | `-Time HH:MM` | Heure du reset |
| `--days …` | `-Days …` | `daily`, `weekdays`, `weekend` ou une liste : `lun,mer,ven` / `mon,wed,fri` |
| `--wake` / `--no-wake` | `-NoWake` | Sortir l'ordi de veille |
| `--message "…"` | `-Message "…"` | Message envoyé à Claude |
| `--warn-days N` | `-WarnDays N` | Délai d'alerte avant expiration (défaut 7) |
| `--dry-run` | `-DryRun` | Génère les fichiers dans `.dry-run/` sans rien installer |

Pour changer l'heure ou les jours, relance simplement l'installateur.

## Utilisation

```bash
~/.claude-morning-reset/claude-reset.sh status   # état, date d'expiration, dernier reset
~/.claude-morning-reset/claude-reset.sh reset    # lancer un reset maintenant
~/.claude-morning-reset/claude-reset.sh check    # vérifier la connexion maintenant
```

Sous Windows : `powershell -File "$env:USERPROFILE\.claude-morning-reset\claude-reset.ps1" status`.

Logs : `~/.claude-morning-reset/logs/claude-reset.log`.

## Ce qui est installé

| | macOS | Linux | Windows |
|---|---|---|---|
| Reset | LaunchAgent `com.claude-morning-reset.run` | timer utilisateur `claude-morning-reset.timer` | tâche `ClaudeMorningReset` |
| Vérification | LaunchAgent `com.claude-morning-reset.check` (session + toutes les 15 min, rattrapé au réveil) | timer `claude-morning-reset-check.timer` + autostart | tâche `ClaudeMorningReset-Check` (session + déverrouillage) |
| Réveil | `pmset repeat wakeorpoweron` (sudo) | timer système `WakeSystem=true` (sudo) | `WakeToRun` sur la tâche |
| Alerte | `osascript` (fenêtre + notification) | `notify-send` ou `zenity` | fenêtre `WScript.Shell` |

## Désinstallation

```bash
./uninstall.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## Limites à connaître

- **Réveil sur portable** : macOS ne sort de veille un portable que branché au secteur. Sous Windows, il faut autoriser les « minuteurs de réveil » dans les options d'alimentation, et certains PC en veille moderne les ignorent.
- **`pmset repeat`** ne garde qu'un seul réveil récurrent : l'installation remplace celui qui existe déjà.
- **Date d'expiration** : elle est lue dans un champ interne des identifiants de Claude Code (`refreshTokenExpiresAt`). Si Claude Code change ce format, cette vérification s'arrête simplement ; la détection de session expirée continue de marcher.
- **macOS** : à la première alerte, macOS peut demander l'autorisation de contrôler Terminal (bouton « Se reconnecter »).
- **Linux** : les timers utilisateur ne tournent que si ta session est ouverte (écran verrouillé, ça va).
- La version Windows n'a pas encore été testée sur une vraie machine Windows.
