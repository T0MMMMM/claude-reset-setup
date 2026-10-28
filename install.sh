#!/usr/bin/env bash
# Installe le reset matinal de Claude Code sur macOS ou Linux.
# Sous Windows, utilise install.ps1.
#
# En une commande :
#   curl -fsSL https://raw.githubusercontent.com/T0MMMMM/claude-reset-setup/main/install.sh | bash
set -euo pipefail

RAW_URL="${CMR_RAW_URL:-https://raw.githubusercontent.com/T0MMMMM/claude-reset-setup/main}"
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
REPO_DIR="$(cd "$(dirname "${SCRIPT_PATH:-.}")" && pwd)"
# Lancé via curl | bash : pas de dépôt local, on télécharge ce qu'il faut.
STANDALONE=0
[ -n "$SCRIPT_PATH" ] && [ -f "$REPO_DIR/bin/claude-reset.sh" ] || STANDALONE=1
# Questions seulement si lancé directement dans un terminal (ou avec --interactive).
INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1
INSTALL_DIR="$HOME/.claude-morning-reset"
AGENTS_DIR="$HOME/Library/LaunchAgents"
SYSTEMD_DIR="$HOME/.config/systemd/user"
AUTOSTART_DIR="$HOME/.config/autostart"
LABEL="com.claude-morning-reset"
UNIT="claude-morning-reset"

TIME=""
DAYS=""
WAKE=""
MESSAGE="Bonjour, réponds juste OK."
WARN_DAYS=7
ALERT_REPEAT_MIN=120
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage : ./install.sh [options]

  --time HH:MM        Heure du reset (ex. 07:30)
  --days JOURS        daily | weekdays | weekend | liste (ex. lun,mer,ven ou mon,wed,fri)
  --wake / --no-wake  Sortir l'ordi de veille 2 min avant (demande sudo)
  --message TEXTE     Message envoyé à Claude (défaut : "Bonjour, réponds juste OK.")
  --warn-days N       Prévenir N jours avant l'expiration de la connexion (défaut : 7)
  --interactive       Poser les questions même via curl | bash
  --dry-run           Génère les fichiers dans ./.dry-run sans rien installer
  -h, --help          Affiche cette aide

Lancé dans un terminal, le script pose les questions.
Via curl | bash, il utilise les défauts : 07:30, du lundi au vendredi, avec réveil.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --time) TIME="${2:-}"; shift 2 ;;
    --days) DAYS="${2:-}"; shift 2 ;;
    --wake) WAKE=1; shift ;;
    --no-wake) WAKE=0; shift ;;
    --message) MESSAGE="${2:-}"; shift 2 ;;
    --warn-days) WARN_DAYS="${2:-}"; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; usage; exit 1 ;;
  esac
done

info() { printf '\033[1;34m›\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
  local answer=""
  # Sans terminal (ex. lancé par un autre programme), on prend la valeur par défaut.
  if [ "$INTERACTIVE" = 1 ] && { exec 3< /dev/tty; } 2>/dev/null; then
    read -r -p "$1 [$2] : " answer <&3 || true
    exec 3<&-
  fi
  echo "${answer:-$2}"
}

confirm() {
  local answer
  answer=$(ask "$1 (o/n)" "$2")
  case "$answer" in o|O|y|Y|oui|yes) return 0 ;; *) return 1 ;; esac
}

run() {
  if [ "$DRY_RUN" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

# Jours : 1 = lundi … 7 = dimanche.
day_number() {
  case "$1" in
    1|lun*|mon*) echo 1 ;;
    2|mar*|tue*) echo 2 ;;
    3|mer*|wed*) echo 3 ;;
    4|jeu*|thu*) echo 4 ;;
    5|ven*|fri*) echo 5 ;;
    6|sam*|sat*) echo 6 ;;
    7|0|dim*|sun*) echo 7 ;;
    *) return 1 ;;
  esac
}

parse_days() {
  local input tok n out=""
  input=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  case "$input" in
    daily|tous|tlj|quotidien|everyday) echo "1 2 3 4 5 6 7"; return ;;
    weekdays|semaine|lun-ven|mon-fri) echo "1 2 3 4 5"; return ;;
    weekend|we) echo "6 7"; return ;;
  esac
  for tok in $(printf '%s' "$input" | tr ',' ' '); do
    n=$(day_number "$tok") || die "Jour inconnu : $tok"
    out="$out $n"
  done
  [ -n "$out" ] || die "Aucun jour choisi."
  printf '%s\n' $out | sort -un | tr '\n' ' ' | sed 's/ $//'
}

map_days() { # map_days "<liste>" "<noms pour 1..7>" "<séparateur>"
  local d out="" names sep="$3"
  # shellcheck disable=SC2206
  names=($2)
  for d in $1; do out="$out${out:+$sep}${names[$((d - 1))]}"; done
  echo "$out"
}

# ---------- Questions ----------

OS=$(detect_os)
case "$OS" in
  macos|linux) ;;
  windows|wsl) die "Sous Windows, lance install.ps1 depuis PowerShell (WSL ne peut pas sortir le PC de veille)." ;;
  *) die "Système non pris en charge : $(uname -s)" ;;
esac
info "Système détecté : $OS"

CLAUDE_BIN=$(command -v claude || true)
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
[ -n "$CLAUDE_BIN" ] || die "Commande claude introuvable. Installe Claude Code d'abord : https://claude.com/claude-code"
info "Claude Code : $CLAUDE_BIN"

[ -n "$TIME" ] || TIME=$(ask "Heure du reset (HH:MM)" "07:30")
[[ "$TIME" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] || die "Heure invalide : $TIME"
HOUR=$((10#${BASH_REMATCH[1]}))
MINUTE=$((10#${BASH_REMATCH[2]}))
TIME=$(printf '%02d:%02d' "$HOUR" "$MINUTE")

if [ -z "$DAYS" ]; then
  [ "$INTERACTIVE" = 1 ] && echo "Récurrence : 1) du lundi au vendredi  2) tous les jours  3) week-end  4) jours au choix"
  case "$(ask "Choix" "1")" in
    1) DAYS=weekdays ;;
    2) DAYS=daily ;;
    3) DAYS=weekend ;;
    4) DAYS=$(ask "Jours séparés par des virgules (ex. lun,mer,ven)" "lun,mar,mer,jeu,ven") ;;
    *) die "Choix invalide." ;;
  esac
fi
DAY_LIST=$(parse_days "$DAYS")
DAYS_LABEL=$(map_days "$DAY_LIST" "lun mar mer jeu ven sam dim" ",")

if [ -z "$WAKE" ]; then
  if confirm "Sortir l'ordi de veille automatiquement avant le reset ? (sudo requis)" "o"; then WAKE=1; else WAKE=0; fi
fi

# Réveil 2 min avant le reset, sauf si ça ferait changer de jour.
WAKE_TOTAL=$((HOUR * 60 + MINUTE - 2))
[ $WAKE_TOTAL -ge 0 ] || WAKE_TOTAL=$((HOUR * 60 + MINUTE))
WAKE_TIME=$(printf '%02d:%02d' $((WAKE_TOTAL / 60)) $((WAKE_TOTAL % 60)))

if [ "$INTERACTIVE" = 0 ]; then
  info "Réglages : reset à $TIME ($DAYS_LABEL), réveil $([ "$WAKE" = 1 ] && echo "à $WAKE_TIME" || echo "désactivé")."
  info "Pour les changer : ... | bash -s -- --time 08:00 --days daily --no-wake (ou --interactive)"
fi

if [ "$DRY_RUN" = 1 ]; then
  PREVIEW="$REPO_DIR/.dry-run"
  rm -rf "$PREVIEW"
  INSTALL_DIR="$PREVIEW/install"
  AGENTS_DIR="$PREVIEW/LaunchAgents"
  SYSTEMD_DIR="$PREVIEW/systemd-user"
  AUTOSTART_DIR="$PREVIEW/autostart"
  warn "Mode dry-run : fichiers générés dans $PREVIEW, rien n'est installé."
fi

# ---------- Fichiers communs ----------

mkdir -p "$INSTALL_DIR/logs" "$INSTALL_DIR/state"
if [ "$STANDALONE" = 1 ]; then
  curl -fsSL "$RAW_URL/bin/claude-reset.sh" -o "$INSTALL_DIR/claude-reset.sh" ||
    die "Téléchargement impossible : $RAW_URL/bin/claude-reset.sh"
else
  cp "$REPO_DIR/bin/claude-reset.sh" "$INSTALL_DIR/claude-reset.sh"
fi
chmod +x "$INSTALL_DIR/claude-reset.sh"
{
  echo "# Généré par install.sh — relance install.sh pour changer ces valeurs."
  printf 'CLAUDE_BIN=%q\n' "$CLAUDE_BIN"
  printf 'RESET_MESSAGE=%q\n' "$MESSAGE"
  printf 'RESET_TIME=%q\n' "$TIME"
  printf 'RESET_DAYS_LABEL=%q\n' "$DAYS_LABEL"
  printf 'WARN_DAYS=%q\n' "$WARN_DAYS"
  printf 'ALERT_REPEAT_MIN=%q\n' "$ALERT_REPEAT_MIN"
  echo "CHECK_EXPIRY=1"
} > "$INSTALL_DIR/config.env"
ok "Script installé dans $INSTALL_DIR"

RUNNER="$INSTALL_DIR/claude-reset.sh"

# ---------- macOS ----------

plist_header() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$RUNNER</string>
    <string>$2</string>
  </array>
  <key>StandardOutPath</key><string>$INSTALL_DIR/logs/launchd.log</string>
  <key>StandardErrorPath</key><string>$INSTALL_DIR/logs/launchd.log</string>
  <!-- Garde la fenêtre d'alerte ouverte après la fin du script. -->
  <key>AbandonProcessGroup</key><true/>
EOF
}

write_run_plist() {
  local d
  plist_header "$LABEL.run" reset
  echo "  <key>StartCalendarInterval</key>"
  echo "  <array>"
  for d in $DAY_LIST; do
    echo "    <dict><key>Weekday</key><integer>$d</integer><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>$MINUTE</integer></dict>"
  done
  echo "  </array>"
  echo "</dict>"
  echo "</plist>"
}

write_check_plist() {
  plist_header "$LABEL.check" check
  cat <<EOF
  <key>RunAtLoad</key><true/>
  <!-- Toutes les 15 min ; après une veille, launchd le relance au réveil. -->
  <key>StartInterval</key><integer>900</integer>
</dict>
</plist>
EOF
}

load_agent() {
  local uid; uid=$(id -u)
  run launchctl bootout "gui/$uid" "$1" 2>/dev/null || true
  run launchctl bootstrap "gui/$uid" "$1"
}

install_macos() {
  local old="$HOME/Library/LaunchAgents/com.user.claude-reset.plist"
  if [ "$DRY_RUN" = 0 ] && [ -f "$old" ]; then
    warn "Ancienne automatisation trouvée : $old"
    if confirm "La désactiver ? (le fichier sera renommé en .bak)" "o"; then
      launchctl bootout "gui/$(id -u)" "$old" 2>/dev/null || true
      mv "$old" "$old.bak"
      ok "Ancienne automatisation désactivée."
    fi
  fi

  mkdir -p "$AGENTS_DIR"
  write_run_plist > "$AGENTS_DIR/$LABEL.run.plist"
  write_check_plist > "$AGENTS_DIR/$LABEL.check.plist"
  plutil -lint -s "$AGENTS_DIR/$LABEL.run.plist" "$AGENTS_DIR/$LABEL.check.plist" || die "plist invalide."
  load_agent "$AGENTS_DIR/$LABEL.run.plist"
  load_agent "$AGENTS_DIR/$LABEL.check.plist"
  ok "Reset programmé à $TIME ($DAYS_LABEL), vérification au réveil et à l'ouverture de session."

  if [ "$WAKE" = 1 ]; then
    local letters
    letters=$(map_days "$DAY_LIST" "M T W R F S U" "")
    if [ "$DRY_RUN" = 0 ] && pmset -g sched | grep -q "Repeating power events"; then
      warn "Un réveil programmé existe déjà, il sera remplacé :"
      pmset -g sched | sed -n '/Repeating/,/Scheduled/p' | grep -v Scheduled
    fi
    info "Réveil programmé à $WAKE_TIME (mot de passe administrateur demandé)."
    run sudo pmset repeat wakeorpoweron "$letters" "$WAKE_TIME:00"
    ok "Réveil programmé à $WAKE_TIME."
    warn "Sur un portable, le réveil ne marche que branché au secteur et écran ouvert (ou avec écran externe)."
  fi
}

# ---------- Linux ----------

install_linux() {
  command -v systemctl >/dev/null 2>&1 || die "systemd est requis sous Linux."
  local cal
  cal="$(map_days "$DAY_LIST" "Mon Tue Wed Thu Fri Sat Sun" ",") *-*-*"

  mkdir -p "$SYSTEMD_DIR" "$AUTOSTART_DIR"
  cat > "$SYSTEMD_DIR/$UNIT.service" <<EOF
[Unit]
Description=Claude Code - reset matinal

[Service]
Type=oneshot
ExecStart=/bin/bash "$RUNNER" reset
EOF
  cat > "$SYSTEMD_DIR/$UNIT.timer" <<EOF
[Unit]
Description=Claude Code - reset matinal à $TIME

[Timer]
OnCalendar=$cal $TIME:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  cat > "$SYSTEMD_DIR/$UNIT-check.service" <<EOF
[Unit]
Description=Claude Code - vérification de la session

[Service]
Type=oneshot
ExecStart=/bin/bash "$RUNNER" check
EOF
  cat > "$SYSTEMD_DIR/$UNIT-check.timer" <<EOF
[Unit]
Description=Claude Code - vérification toutes les 15 min

[Timer]
OnStartupSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
  cat > "$AUTOSTART_DIR/$UNIT-check.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Claude morning reset - vérification
Exec=/bin/bash "$RUNNER" check
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
  run systemctl --user daemon-reload
  run systemctl --user enable --now "$UNIT.timer" "$UNIT-check.timer"
  ok "Reset programmé à $TIME ($DAYS_LABEL), vérification à l'ouverture de session et toutes les 15 min."

  if [ "$WAKE" = 1 ]; then
    info "Réveil programmé à $WAKE_TIME (mot de passe administrateur demandé)."
    local wake_service wake_timer
    wake_service="[Unit]
Description=Claude Code - sortie de veille

[Service]
Type=oneshot
ExecStart=/bin/true"
    wake_timer="[Unit]
Description=Claude Code - sortie de veille à $WAKE_TIME

[Timer]
OnCalendar=$cal $WAKE_TIME:00
WakeSystem=true

[Install]
WantedBy=timers.target"
    if [ "$DRY_RUN" = 1 ]; then
      printf '%s\n' "$wake_service" > "$PREVIEW/$UNIT-wake.service"
      printf '%s\n' "$wake_timer" > "$PREVIEW/$UNIT-wake.timer"
    else
      printf '%s\n' "$wake_service" | sudo tee "/etc/systemd/system/$UNIT-wake.service" >/dev/null
      printf '%s\n' "$wake_timer" | sudo tee "/etc/systemd/system/$UNIT-wake.timer" >/dev/null
    fi
    run sudo systemctl daemon-reload
    run sudo systemctl enable --now "$UNIT-wake.timer"
    ok "Réveil programmé à $WAKE_TIME."
  fi
  warn "Les timers utilisateur ne tournent que si ta session est ouverte (écran verrouillé ok)."
}

case "$OS" in
  macos) install_macos ;;
  linux) install_linux ;;
esac

echo
ok "Installation terminée."
echo "   État        : $RUNNER status"
echo "   Tester      : $RUNNER reset"
echo "   Logs        : $INSTALL_DIR/logs/claude-reset.log"
if [ "$STANDALONE" = 1 ]; then
  echo "   Désinstaller: curl -fsSL $RAW_URL/uninstall.sh | bash"
else
  echo "   Désinstaller: $REPO_DIR/uninstall.sh"
fi

if [ "$DRY_RUN" = 0 ]; then
  echo
  "$RUNNER" status || true
  if confirm "Envoyer le message à Claude maintenant pour tester ?" "n"; then
    "$RUNNER" reset && ok "Test réussi." || warn "Le test a échoué, voir le log ci-dessus."
  fi
fi
