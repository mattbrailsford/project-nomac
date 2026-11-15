# shellcheck shell=bash
# Shared helpers. Must stay compatible with macOS's stock bash 3.2:
# no associative arrays, no ${var,,}, no mapfile, no `sed -i`.

NOMAC_HOME="${NOMAC_HOME:-$HOME/.nomac}"
NOMAC_ENV="$NOMAC_HOME/.env"
NOMAC_COMPOSE="$NOMAC_HOME/compose.yaml"
NOMAC_UPSTREAM="$NOMAC_HOME/upstream"
NOMAC_STATE="$NOMAC_HOME/state"
NOMAC_LOGS="$NOMAC_HOME/logs"
UPSTREAM_URL="https://github.com/Crosstalk-Solutions/project-nomad.git"
IMAGE_REPO="nomac/project-nomad"
EMBEDDING_MODEL="nomic-embed-text:v1.5"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
AGENT_PREFIX="com.nomac"

# Homebrew on Apple Silicon is in /opt/homebrew; launchd jobs get a bare PATH.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.orbstack/bin:$PATH"

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLD" "$C_OFF" "$*"; }
ok()    { printf '%s ✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '%s !%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()   { printf '%s ✗%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ask "Question" default(y/n) -> returns 0 for yes
ask() {
  local q="$1" def="${2:-n}" ans hint="[y/N]"
  [ "$def" = "y" ] && hint="[Y/n]"
  if [ "${NOMAC_YES:-0}" = "1" ] || [ ! -t 0 ]; then
    [ "$def" = "y" ]; return
  fi
  read -r -p "$q $hint " ans
  ans="${ans:-$def}"
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

load_config() {
  local conf="${NOMAC_CONF:-$NOMAC_REPO/nomac.conf}"
  [ -f "$conf" ] || conf="$NOMAC_REPO/nomac.conf.example"
  # shellcheck disable=SC1090
  . "$conf"
  STORAGE_PATH="${STORAGE_PATH%/}"
  NOMAD_PORT="${NOMAD_PORT:-8080}"
  NOMAD_URL="${NOMAD_URL:-http://localhost:$NOMAD_PORT}"
  DOZZLE_PORT="${DOZZLE_PORT:-9999}"
  OLLAMA_BIND="${OLLAMA_BIND:-0.0.0.0:11434}"
  OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-10m}"
  MIN_FREE_GB="${MIN_FREE_GB:-30}"
  MAP_MAX_ZOOM="${MAP_MAX_ZOOM:-14}"
  DOCKER_RUNTIME="${DOCKER_RUNTIME:-orbstack}"
  case "$STORAGE_PATH" in
    *" "*) die "STORAGE_PATH must not contain spaces: $STORAGE_PATH" ;;
    /*) ;;
    *) die "STORAGE_PATH must be an absolute path: $STORAGE_PATH" ;;
  esac
}

# Read KEY from ~/.nomac/.env
env_get() {
  [ -f "$NOMAC_ENV" ] || return 0
  grep -E "^$1=" "$NOMAC_ENV" | tail -n 1 | cut -d= -f2- || true
}

# Set KEY=VALUE in ~/.nomac/.env (portable; no sed -i)
env_set() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp "$NOMAC_HOME/.env.XXXXXX")"
  if [ -f "$NOMAC_ENV" ]; then
    grep -vE "^$key=" "$NOMAC_ENV" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$NOMAC_ENV"
}

compose() {
  local profiles=""
  [ "${DOZZLE:-true}" = "true" ] && profiles="--profile dozzle"
  # shellcheck disable=SC2086
  docker compose --project-directory "$NOMAC_HOME" --env-file "$NOMAC_ENV" \
    -f "$NOMAC_COMPOSE" $profiles "$@"
}

docker_ready() { docker info >/dev/null 2>&1; }

ollama_url() { echo "http://127.0.0.1:${OLLAMA_BIND##*:}"; }
ollama_ready() { curl -fsS -m 3 "$(ollama_url)/api/version" >/dev/null 2>&1; }
nomad_ready() { curl -fsS -m 5 "http://localhost:$NOMAD_PORT/api/health" >/dev/null 2>&1; }

# Wait up to $2 seconds for command $1 to succeed.
wait_for() {
  local check="$1" secs="${2:-120}" i=0
  while ! "$check"; do
    i=$((i + 2)); [ "$i" -ge "$secs" ] && return 1
    sleep 2
  done
}

online() { curl -fsS -m 5 -o /dev/null https://api.github.com 2>/dev/null; }

# Strict semver (optionally v-prefixed) — the update request file is written by
# a container, so treat its contents as untrusted.
is_semver() { printf '%s' "$1" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$'; }

latest_upstream_version() {
  git ls-remote --tags --refs "$UPSTREAM_URL" 'v*' 2>/dev/null \
    | sed 's|.*refs/tags/v||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true
}

# Free GB on the filesystem holding $1 (portable: BSD and GNU df).
free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; }

check_free_space() {
  local path="$1" free
  free="$(free_gb "$path")"
  [ -n "$free" ] || return 0
  if [ "$free" -lt "$MIN_FREE_GB" ]; then
    warn "Only ${free} GB free on the drive holding $path (threshold ${MIN_FREE_GB} GB)."
    return 1
  fi
}
