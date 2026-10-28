#!/usr/bin/env bash
# Envoie le message de reset à Claude Code et alerte si la session a expiré.
# Usage : claude-reset.sh reset|check|status
#   reset  : envoie le message (lancé à l'heure choisie)
#   check  : vérifie la connexion (lancé à l'ouverture de session et au réveil)
#   status : affiche l'état actuel
set -uo pipefail

MODE="${1:-check}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/config.env"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
OS="$(uname -s)"
STATE_DIR="$DIR/state"
LOG="$DIR/logs/claude-reset.log"
AUTH_PATTERN='authenticat|oauth|not logged in|please log ?in|/login|invalid api key'
LOGIN_HINT="Ouvre un terminal et lance : claude auth login"

mkdir -p "$STATE_DIR" "$DIR/logs"

# Rotation simple au-delà de 1 Mo.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
  mv "$LOG" "$LOG.1"
fi

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$LOG"; }

fmt_date() {
  if [ "$OS" = Darwin ]; then date -r "$1" '+%d/%m/%Y %H:%M'; else date -d "@$1" '+%d/%m/%Y %H:%M'; fi
}

save_result() { printf '%s|%s|%s\n' "$1" "$(date '+%Y-%m-%d %H:%M:%S')" "$2" > "$STATE_DIR/last_result"; }
last_result() { cut -d'|' -f1 "$STATE_DIR/last_result" 2>/dev/null || true; }

# Une alerte donnée ne se répète pas plus d'une fois toutes les N minutes (0 = toujours).
should_alert() {
  local f="$STATE_DIR/alert_$1" now last
  now=$(date +%s)
  last=$(cat "$f" 2>/dev/null || echo 0)
  [ $((now - last)) -ge $(($2 * 60)) ] || return 1
  echo "$now" > "$f"
}

alert_macos() {
  local level="$1" title="$2" msg="$3" icon=warning
  [ "$level" = critical ] && icon=critical
  osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true
  # La fenêtre reste affichée jusqu'au clic : on la voit en ouvrant l'ordi.
  (
    btn=$(osascript \
      -e "display alert \"$title\" message \"$msg\" as $icon buttons {\"Plus tard\", \"Se reconnecter\"} default button \"Se reconnecter\"" \
      -e 'button returned of result' 2>/dev/null)
    if [ "$btn" = "Se reconnecter" ]; then
      osascript -e "tell application \"Terminal\" to do script \"'$CLAUDE_BIN' auth login\"" \
        -e 'tell application "Terminal" to activate' >/dev/null 2>&1
    fi
  ) &
}

alert_linux() {
  local level="$1" title="$2" msg="$3" urgency=normal
  [ "$level" = critical ] && urgency=critical
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u "$urgency" -a "Claude" "$title" "$msg" || true
  elif command -v zenity >/dev/null 2>&1; then
    (zenity --warning --title "$title" --text "$msg" >/dev/null 2>&1 &)
  fi
}

# alert <clé> <répétition en min> <critical|warning> <titre> <message>
alert() {
  local key="$1" every="$2" level="$3" title="$4" msg
  msg=$(printf '%s' "$5" | tr -d '"\\')
  should_alert "$key" "$every" || return 0
  log "ALERTE ($key) : $msg"
  if [ "${CMR_DRY_ALERT:-0}" = 1 ]; then
    echo "[alerte $level] $title — $msg"
    return 0
  fi
  case "$OS" in
    Darwin) alert_macos "$level" "$title" "$msg" ;;
    Linux) alert_linux "$level" "$title" "$msg" ;;
  esac
}

# 0 = connecté, 1 = déconnecté, 2 = inconnu
login_state() {
  local out
  out=$("$CLAUDE_BIN" auth status 2>/dev/null) || true
  if printf '%s' "$out" | grep -Eq '"loggedIn": *true'; then return 0; fi
  if printf '%s' "$out" | grep -Eq '"loggedIn": *false'; then return 1; fi
  return 2
}

# Date de fin du jeton de renouvellement (secondes). Champ interne à Claude Code :
# s'il disparaît ou change de nom, la vérification est simplement ignorée.
refresh_expiry() {
  [ "${CHECK_EXPIRY:-1}" = 1 ] || return 1
  local raw="" ms
  if [ "$OS" = Darwin ]; then
    raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || raw=""
  fi
  if [ -z "$raw" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    raw=$(cat "$HOME/.claude/.credentials.json")
  fi
  ms=$(printf '%s' "$raw" | grep -o '"refreshTokenExpiresAt": *[0-9]*' | head -n1 | grep -o '[0-9]*$')
  raw=""
  [ -n "$ms" ] && [ "$ms" -gt 0 ] || return 1
  echo $((ms / 1000))
}

check_expiry() {
  local exp now days
  exp=$(refresh_expiry) || return 0
  now=$(date +%s)
  days=$(((exp - now) / 86400))
  if [ "$exp" -le "$now" ]; then
    alert refresh_expired 1440 critical "Connexion Claude expirée" \
      "Ta connexion Claude Code ne peut plus se renouveler depuis le $(fmt_date "$exp"). $LOGIN_HINT"
  elif [ "$days" -lt "$WARN_DAYS" ]; then
    alert refresh_soon 1440 warning "Connexion Claude bientôt expirée" \
      "Ta connexion Claude Code expire le $(fmt_date "$exp") (dans $days j). $LOGIN_HINT"
  fi
}

wait_network() {
  local i
  for i in $(seq 1 24); do
    curl -s -m 5 -o /dev/null https://api.anthropic.com && return 0
    sleep 5
  done
  return 1
}

do_reset() {
  local out code attempt last_line
  log "Envoi du message à Claude…"
  wait_network || log "Réseau indisponible après 2 min, on tente quand même."
  for attempt in 1 2 3; do
    if [ "$OS" = Darwin ]; then
      out=$(cd "$HOME" && caffeinate -i "$CLAUDE_BIN" -p "$RESET_MESSAGE" 2>&1)
    else
      out=$(cd "$HOME" && "$CLAUDE_BIN" -p "$RESET_MESSAGE" 2>&1)
    fi
    code=$?
    last_line=$(printf '%s' "$out" | tail -n1)

    if [ $code -eq 0 ] && ! printf '%s' "$out" | grep -qi 'failed to authenticate'; then
      log "OK : $last_line"
      save_result ok "$last_line"
      check_expiry
      return 0
    fi
    if printf '%s' "$out" | grep -Eqi "$AUTH_PATTERN"; then
      log "Session expirée : $last_line"
      save_result auth_expired "$last_line"
      alert auth_expired 0 critical "Session Claude expirée" \
        "Le reset de $(date '+%H:%M') a échoué : Claude Code n'est plus connecté. $LOGIN_HINT"
      return 1
    fi
    log "Échec (tentative $attempt/3, code $code) : $last_line"
    [ $attempt -lt 3 ] && sleep 60
  done
  save_result error "$last_line"
  alert run_error 0 warning "Reset Claude échoué" \
    "Le reset de $(date '+%H:%M') a échoué (voir $LOG)."
  return 1
}

do_check() {
  local state
  login_state; state=$?
  if [ $state -eq 1 ]; then
    alert not_logged_in "$ALERT_REPEAT_MIN" critical "Session Claude expirée" \
      "Claude Code n'est plus connecté : le prochain reset va échouer. $LOGIN_HINT"
    return 1
  fi
  case "$(last_result)" in
    # Claude Code se marque déconnecté après un échec : connecté maintenant = reconnecté.
    auth_expired) [ $state -eq 0 ] && save_result relogged "Reconnecté après échec" ;;
    error) alert run_error_check 1440 warning "Reset Claude échoué" \
      "Le dernier reset a échoué (voir $LOG)." ;;
  esac
  check_expiry
}

do_status() {
  local exp
  echo "Heure du reset : $RESET_TIME (jours : $RESET_DAYS_LABEL)"
  echo "Claude         : $CLAUDE_BIN"
  printf 'Connexion      : '
  login_state
  case $? in 0) echo "connecté" ;; 1) echo "DÉCONNECTÉ" ;; *) echo "inconnue" ;; esac
  if exp=$(refresh_expiry); then echo "Expire le      : $(fmt_date "$exp")"; fi
  if [ -f "$STATE_DIR/last_result" ]; then
    IFS='|' read -r st when msg < "$STATE_DIR/last_result"
    echo "Dernier reset  : $st le $when ($msg)"
  else
    echo "Dernier reset  : jamais"
  fi
  echo "Log            : $LOG"
}

case "$MODE" in
  reset) do_reset ;;
  check) do_check ;;
  status) do_status ;;
  *) echo "Usage : $0 reset|check|status" >&2; exit 2 ;;
esac
