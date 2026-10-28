#!/usr/bin/env bash
# Envoie le message de reset à Claude Code pour chaque compte et alerte si une session a expiré.
# Usage :
#   claude-reset reset            envoie le message à chaque compte (lancé à l'heure choisie)
#   claude-reset check            vérifie les connexions (ouverture de session, réveil)
#   claude-reset status           affiche l'état de chaque compte
#   claude-reset login [NOM]      (re)connecte un compte
#   claude-reset account list | add NOM | remove NOM
set -uo pipefail

MODE="${1:-check}"
SELF="${BASH_SOURCE[0]}"
# Appelé via le lien ~/.local/bin/claude-reset : on retrouve le vrai dossier.
[ -L "$SELF" ] && SELF="$(readlink "$SELF")"
DIR="$(cd "$(dirname "$SELF")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/config.env"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
OS="$(uname -s)"
STATE_DIR="$DIR/state"
LOG="$DIR/logs/claude-reset.log"
ACCOUNTS_FILE="$DIR/accounts.conf"
ACCOUNTS_DIR="${CMR_ACCOUNTS_DIR:-$HOME/.claude-accounts}"
AUTH_PATTERN='authenticat|oauth|not logged in|please log ?in|/login|invalid api key'

mkdir -p "$STATE_DIR" "$DIR/logs"

# Rotation simple au-delà de 1 Mo.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
  mv "$LOG" "$LOG.1"
fi

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$MODE" "$*" >> "$LOG"; }
die() { echo "$*" >&2; exit 1; }

fmt_date() {
  if [ "$OS" = Darwin ]; then date -r "$1" '+%d/%m/%Y %H:%M'; else date -d "@$1" '+%d/%m/%Y %H:%M'; fi
}

# ---------- Comptes ----------
# accounts.conf : une ligne « nom|dossier de config » ; dossier vide = config par défaut (~/.claude).

list_accounts() {
  if [ -f "$ACCOUNTS_FILE" ]; then grep -v '^#' "$ACCOUNTS_FILE" | grep '|'; else echo "principal|"; fi
}

account_dir() {
  list_accounts | awk -F'|' -v n="$1" '$1 == n { print $2; found = 1 } END { exit !found }'
}

claude_as() {
  local dir="$1"
  shift
  if [ -n "$dir" ]; then CLAUDE_CONFIG_DIR="$dir" "$CLAUDE_BIN" "$@"; else "$CLAUDE_BIN" "$@"; fi
}

login_hint() { echo "Lance : claude-reset login $1"; }

# ---------- État et alertes (par compte) ----------

save_result() { mkdir -p "$STATE_DIR/$1"; printf '%s|%s|%s\n' "$2" "$(date '+%Y-%m-%d %H:%M:%S')" "$3" > "$STATE_DIR/$1/last_result"; }
last_result() { cut -d'|' -f1 "$STATE_DIR/$1/last_result" 2>/dev/null || true; }

# Une alerte donnée ne se répète pas plus d'une fois toutes les N minutes (0 = toujours).
should_alert() {
  local f="$STATE_DIR/$1/alert_$2" now last
  mkdir -p "$STATE_DIR/$1"
  now=$(date +%s)
  last=$(cat "$f" 2>/dev/null || echo 0)
  [ $((now - last)) -ge $(($3 * 60)) ] || return 1
  echo "$now" > "$f"
}

alert_macos() {
  local account="$1" level="$2" title="$3" msg="$4" icon=warning
  [ "$level" = critical ] && icon=critical
  osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true
  # La fenêtre reste affichée jusqu'au clic : on la voit en ouvrant l'ordi.
  (
    btn=$(osascript \
      -e "display alert \"$title\" message \"$msg\" as $icon buttons {\"Plus tard\", \"Se reconnecter\"} default button \"Se reconnecter\"" \
      -e 'button returned of result' 2>/dev/null)
    if [ "$btn" = "Se reconnecter" ]; then
      osascript -e "tell application \"Terminal\" to do script \"'$DIR/claude-reset.sh' login '$account'\"" \
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

# alert <compte> <clé> <répétition en min> <critical|warning> <titre> <message>
alert() {
  local account="$1" key="$2" every="$3" level="$4" title msg
  title="$5 ($account)"
  msg=$(printf '%s' "$6" | tr -d '"\\')
  should_alert "$account" "$key" "$every" || return 0
  log "ALERTE ($account/$key) : $msg"
  if [ "${CMR_DRY_ALERT:-0}" = 1 ]; then
    echo "[alerte $level] $title — $msg"
    return 0
  fi
  case "$OS" in
    Darwin) alert_macos "$account" "$level" "$title" "$msg" ;;
    Linux) alert_linux "$level" "$title" "$msg" ;;
  esac
}

# 0 = connecté, 1 = déconnecté, 2 = inconnu
login_state() {
  local out
  out=$(claude_as "$1" auth status 2>/dev/null) || true
  if printf '%s' "$out" | grep -Eq '"loggedIn": *true'; then return 0; fi
  if printf '%s' "$out" | grep -Eq '"loggedIn": *false'; then return 1; fi
  return 2
}

# Date de fin du jeton de renouvellement (secondes). Champ interne à Claude Code :
# s'il disparaît ou change de nom, la vérification est simplement ignorée.
refresh_expiry() {
  [ "${CHECK_EXPIRY:-1}" = 1 ] || return 1
  local dir="$1" raw="" ms service="Claude Code-credentials"
  if [ "$OS" = Darwin ]; then
    # Avec CLAUDE_CONFIG_DIR, Claude Code suffixe l'entrée du trousseau par un hash du dossier.
    [ -n "$dir" ] && service="$service-$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"
    raw=$(security find-generic-password -s "$service" -w 2>/dev/null) || raw=""
  fi
  if [ -z "$raw" ] && [ -f "${dir:-$HOME/.claude}/.credentials.json" ]; then
    raw=$(cat "${dir:-$HOME/.claude}/.credentials.json")
  fi
  ms=$(printf '%s' "$raw" | grep -o '"refreshTokenExpiresAt": *[0-9]*' | head -n1 | grep -o '[0-9]*$')
  raw=""
  [ -n "$ms" ] && [ "$ms" -gt 0 ] || return 1
  echo $((ms / 1000))
}

check_expiry() {
  local account="$1" exp now days
  exp=$(refresh_expiry "$2") || return 0
  now=$(date +%s)
  days=$(((exp - now) / 86400))
  if [ "$exp" -le "$now" ]; then
    alert "$account" refresh_expired 1440 critical "Connexion Claude expirée" \
      "La connexion ne peut plus se renouveler depuis le $(fmt_date "$exp"). $(login_hint "$account")"
  elif [ "$days" -lt "$WARN_DAYS" ]; then
    alert "$account" refresh_soon 1440 warning "Connexion Claude bientôt expirée" \
      "La connexion expire le $(fmt_date "$exp") (dans $days j). Reconnecte-toi avant. $(login_hint "$account")"
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

# ---------- Commandes ----------

reset_account() {
  local account="$1" dir="$2" out code attempt last_line
  log "[$account] Envoi du message à Claude…"
  for attempt in 1 2 3; do
    out=$(cd "$HOME" && claude_as "$dir" -p "$RESET_MESSAGE" 2>&1)
    code=$?
    last_line=$(printf '%s' "$out" | tail -n1)

    if [ $code -eq 0 ] && ! printf '%s' "$out" | grep -qi 'failed to authenticate'; then
      log "[$account] OK : $last_line"
      save_result "$account" ok "$last_line"
      check_expiry "$account" "$dir"
      return 0
    fi
    if printf '%s' "$out" | grep -Eqi "$AUTH_PATTERN"; then
      log "[$account] Session expirée : $last_line"
      save_result "$account" auth_expired "$last_line"
      alert "$account" auth_expired 0 critical "Session Claude expirée" \
        "Le reset de $(date '+%H:%M') a échoué : ce compte n'est plus connecté. $(login_hint "$account")"
      return 1
    fi
    log "[$account] Échec (tentative $attempt/3, code $code) : $last_line"
    [ $attempt -lt 3 ] && sleep 60
  done
  save_result "$account" error "$last_line"
  alert "$account" run_error 0 warning "Reset Claude échoué" \
    "Le reset de $(date '+%H:%M') a échoué (voir $LOG)."
  return 1
}

check_account() {
  local account="$1" dir="$2" state
  login_state "$dir"; state=$?
  if [ $state -eq 1 ]; then
    alert "$account" not_logged_in "$ALERT_REPEAT_MIN" critical "Session Claude expirée" \
      "Ce compte n'est plus connecté : le prochain reset va échouer. $(login_hint "$account")"
    return 1
  fi
  case "$(last_result "$account")" in
    # Claude Code se marque déconnecté après un échec : connecté maintenant = reconnecté.
    auth_expired) [ $state -eq 0 ] && save_result "$account" relogged "Reconnecté après échec" ;;
    error) alert "$account" run_error_check 1440 warning "Reset Claude échoué" \
      "Le dernier reset a échoué (voir $LOG)." ;;
  esac
  check_expiry "$account" "$2"
}

do_reset() {
  local failed=0 account dir
  # Empêche la mise en veille tant que ce script tourne.
  [ "$OS" = Darwin ] && caffeinate -i -w $$ &
  wait_network || log "Réseau indisponible après 2 min, on tente quand même."
  while IFS='|' read -r account dir; do
    reset_account "$account" "$dir" < /dev/null || failed=1
  done < <(list_accounts)
  return $failed
}

do_check() {
  local failed=0 account dir
  while IFS='|' read -r account dir; do
    check_account "$account" "$dir" < /dev/null || failed=1
  done < <(list_accounts)
  return $failed
}

do_status() {
  local account dir exp st when msg conn
  echo "Heure du reset : $RESET_TIME (jours : $RESET_DAYS_LABEL)"
  echo "Log            : $LOG"
  echo
  # Valeurs sans accents : printf aligne en octets, pas en caractères.
  printf '%-14s %-10s %-18s %s\n' "COMPTE" "CONNECTE" "EXPIRE LE" "DERNIER RESET"
  while IFS='|' read -r account dir; do
    login_state "$dir" < /dev/null
    case $? in 0) conn="oui" ;; 1) conn="NON" ;; *) conn="?" ;; esac
    exp=$(refresh_expiry "$dir" < /dev/null) && exp=$(fmt_date "$exp") || exp="-"
    if [ -f "$STATE_DIR/$account/last_result" ]; then
      IFS='|' read -r st when msg < "$STATE_DIR/$account/last_result"
      when="$st le $when"
    else
      when="jamais"
    fi
    printf '%-14s %-10s %-18s %s\n' "$account" "$conn" "$exp" "$when"
  done < <(list_accounts)
}

do_login() {
  local account="${1:-principal}" dir
  dir=$(account_dir "$account") || die "Compte inconnu : $account (voir : claude-reset account list)"
  echo "Connexion du compte « $account »…"
  claude_as "$dir" auth login || return 1
  if login_state "$dir"; then
    save_result "$account" relogged "Reconnecté"
    echo "✓ Compte « $account » connecté."
  fi
}

account_cmd() {
  local action="${1:-list}" name="${2:-}" dir tmp
  case "$action" in
    list)
      list_accounts | while IFS='|' read -r name dir; do
        printf '%-14s %s\n' "$name" "${dir:-~/.claude (config par défaut)}"
      done
      ;;
    add)
      [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Nom invalide : utilise lettres, chiffres, - et _ (ex. perso)."
      account_dir "$name" >/dev/null && die "Le compte « $name » existe déjà."
      dir="$ACCOUNTS_DIR/$name"
      mkdir -p "$dir"
      [ -f "$ACCOUNTS_FILE" ] || echo "principal|" > "$ACCOUNTS_FILE"
      echo "$name|$dir" >> "$ACCOUNTS_FILE"
      echo "✓ Compte « $name » ajouté (config : $dir)."
      echo "  Pour l'utiliser au quotidien : alias claude-$name='CLAUDE_CONFIG_DIR=\"$dir\" claude'"
      if [ -t 0 ]; then do_login "$name"; else echo "  Connecte-le : claude-reset login $name"; fi
      ;;
    remove)
      account_dir "$name" >/dev/null || die "Compte inconnu : $name"
      [ "$(list_accounts | wc -l)" -gt 1 ] || die "Impossible de retirer le dernier compte."
      tmp="$ACCOUNTS_FILE.tmp"
      list_accounts | awk -F'|' -v n="$name" '$1 != n' > "$tmp" && mv "$tmp" "$ACCOUNTS_FILE"
      rm -rf "${STATE_DIR:?}/$name"
      echo "✓ Compte « $name » retiré du reset."
      dir="$ACCOUNTS_DIR/$name"
      [ -d "$dir" ] && echo "  Sa config reste dans $dir (supprime-la toi-même si besoin)."
      ;;
    *) die "Usage : claude-reset account list | add NOM | remove NOM" ;;
  esac
}

case "$MODE" in
  reset) do_reset ;;
  check) do_check ;;
  status) do_status ;;
  login) do_login "${2:-}" ;;
  account) account_cmd "${2:-list}" "${3:-}" ;;
  *) die "Usage : claude-reset reset | check | status | login [NOM] | account list|add|remove" ;;
esac
