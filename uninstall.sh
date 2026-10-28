#!/usr/bin/env bash
# Désinstalle le reset matinal de Claude Code (macOS / Linux).
set -uo pipefail

INSTALL_DIR="$HOME/.claude-morning-reset"
LABEL="com.claude-morning-reset"
UNIT="claude-morning-reset"

ok() { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
confirm() {
  local answer=""
  if { exec 3< /dev/tty; } 2>/dev/null; then
    read -r -p "$1 (o/n) [$2] : " answer <&3 || true
    exec 3<&-
  fi
  case "${answer:-$2}" in o|O|y|Y|oui|yes) return 0 ;; *) return 1 ;; esac
}

case "$(uname -s)" in
  Darwin)
    for job in run check; do
      plist="$HOME/Library/LaunchAgents/$LABEL.$job.plist"
      launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
      rm -f "$plist"
    done
    ok "Tâches launchd supprimées."
    if pmset -g sched | grep -q "Repeating power events" &&
      confirm "Supprimer aussi le réveil programmé (pmset) ? sudo requis" "o"; then
      sudo pmset repeat cancel && ok "Réveil programmé supprimé."
    fi
    ;;
  Linux)
    systemctl --user disable --now "$UNIT.timer" "$UNIT-check.timer" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$UNIT".{service,timer} \
      "$HOME/.config/systemd/user/$UNIT-check".{service,timer} \
      "$HOME/.config/autostart/$UNIT-check.desktop"
    systemctl --user daemon-reload
    ok "Timers utilisateur supprimés."
    if [ -f "/etc/systemd/system/$UNIT-wake.timer" ] &&
      confirm "Supprimer aussi le réveil programmé ? sudo requis" "o"; then
      sudo systemctl disable --now "$UNIT-wake.timer"
      sudo rm -f "/etc/systemd/system/$UNIT-wake".{service,timer}
      sudo systemctl daemon-reload
      ok "Réveil programmé supprimé."
    fi
    ;;
  *) echo "Sous Windows, utilise uninstall.ps1." >&2; exit 1 ;;
esac

rm -f "$HOME/.local/bin/claude-reset"
ok "Commande claude-reset supprimée."

if [ -d "$INSTALL_DIR" ] && confirm "Supprimer $INSTALL_DIR (script, config et logs) ?" "o"; then
  rm -rf "$INSTALL_DIR" && ok "Dossier supprimé."
fi
# Les comptes supplémentaires peuvent servir en dehors du reset : on ne les supprime que sur demande.
if [ -d "$HOME/.claude-accounts" ] &&
  confirm "Supprimer aussi les comptes supplémentaires (~/.claude-accounts) ? Il faudra les reconnecter." "n"; then
  rm -rf "$HOME/.claude-accounts" && ok "Comptes supplémentaires supprimés."
fi
ok "Désinstallation terminée."
