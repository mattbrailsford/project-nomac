# shellcheck shell=bash
# install / start / stop / uninstall and content seeding (models, maps).

# Rewrite KEY="value" in nomac.conf (portable; no sed -i).
conf_set() {
  local key="$1" val="$2" conf="$NOMAC_REPO/nomac.conf" tmp
  tmp="$(mktemp "$NOMAC_REPO/.nomac.conf.XXXXXX")"
  awk -v k="$key" -v v="$val" 'BEGIN{done=0}
    $0 ~ "^"k"=" {print k"=\""v"\""; done=1; next} {print}
    END{if(!done) print k"=\""v"\""}' "$conf" > "$tmp"
  mv "$tmp" "$conf"
}

first_run_questions() {
  local conf="$NOMAC_REPO/nomac.conf" choice path vols countries
  [ -f "$conf" ] && return 0
  cp "$NOMAC_REPO/nomac.conf.example" "$conf"
  info "First run — a few questions (saved to nomac.conf; edit it any time)."
  [ "${NOMAC_YES:-0}" = "1" ] || [ ! -t 0 ] && return 0

  echo
  echo "Where should offline content (Wikipedia, maps, courses) be stored?"
  echo "  1) Internal drive: $HOME/ProjectNomad"
  vols="$(find /Volumes -mindepth 1 -maxdepth 1 -type d ! -name 'Macintosh HD*' 2>/dev/null || true)"
  if [ -n "$vols" ]; then
    echo "  2) External drive — connected now:"
    echo "$vols" | sed 's/^/       /'
  else
    echo "  2) External drive (none connected right now)"
  fi
  read -r -p "Choose 1 or 2 [1]: " choice
  if [ "${choice:-1}" = "2" ]; then
    read -r -p "Folder on the drive (e.g. /Volumes/NomadSSD/nomad): " path
    case "$path" in
      /Volumes/*/*) conf_set STORAGE_PATH "$path" ;;
      *) warn "Expected /Volumes/<Drive>/<folder>; keeping the internal drive." ;;
    esac
  fi

  echo
  read -r -p "Map countries to download, as ISO codes (space separated) [GB]: " countries
  [ -n "$countries" ] && conf_set MAP_COUNTRIES "$(echo "$countries" | tr '[:lower:]' '[:upper:]')"
  echo
}

ensure_brew() {
  command -v brew >/dev/null || die "Homebrew is required. Install it from https://brew.sh, then re-run ./nomac install"
}

brew_install() {
  local f
  for f in "$@"; do
    brew list --formula "$f" >/dev/null 2>&1 || { info "Installing $f"; brew install "$f"; }
  done
}

ensure_docker() {
  if docker_ready; then ok "Docker is running ($(docker info --format '{{.OperatingSystem}}' 2>/dev/null))"; return; fi
  case "$DOCKER_RUNTIME" in
    orbstack)
      if [ ! -d /Applications/OrbStack.app ]; then
        info "Installing OrbStack"
        brew install --cask orbstack
      fi
      info "Starting OrbStack (finish its first-run window if one appears)"
      open -a OrbStack
      wait_for docker_ready 300 || die "Docker did not start. Open OrbStack, finish setup, then re-run."
      # Cap the Linux VM so the LLM keeps most of the 16 GB (best effort).
      orb config set memory_mib 6144 >/dev/null 2>&1 || warn "Could not set OrbStack memory limit; set it to ~6 GB in OrbStack settings."
      ;;
    colima)
      brew_install colima docker docker-compose docker-buildx
      mkdir -p "$HOME/.docker"
      [ -f "$HOME/.docker/config.json" ] || echo '{}' > "$HOME/.docker/config.json"
      jq '.cliPluginsExtraDirs = ["/opt/homebrew/lib/docker/cli-plugins"]' "$HOME/.docker/config.json" > "$HOME/.docker/config.json.tmp" \
        && mv "$HOME/.docker/config.json.tmp" "$HOME/.docker/config.json"
      info "Starting Colima"
      colima start --arch aarch64 --vm-type vz --vz-rosetta --mount-type virtiofs \
        --cpu 4 --memory 6 --disk 60 --mount "$HOME:w" --mount /Volumes:w
      wait_for docker_ready 120 || die "Docker (Colima) did not start."
      ;;
    *) die "Unknown DOCKER_RUNTIME '$DOCKER_RUNTIME' (use orbstack or colima)" ;;
  esac
  ok "Docker is running"
}

ensure_ollama() {
  brew_install ollama
  if pgrep -x Ollama >/dev/null 2>&1; then
    warn "The Ollama desktop app is running — quit it (and remove it from Login Items); nomac runs Ollama itself."
  fi
  brew services stop ollama >/dev/null 2>&1 || true
  write_ollama_agent
  load_agent ollama
  wait_for ollama_ready 60 || die "Ollama did not start — see $NOMAC_LOGS/ollama.log"
  ok "Ollama $(ollama --version 2>/dev/null | awk '{print $NF}') running natively on $(ollama_url)"
}

pull_models() {
  local m installed
  installed="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
  for m in $EMBEDDING_MODEL ${MODELS:-}; do
    if echo "$installed" | grep -qxF "$m" || echo "$installed" | grep -qxF "$m:latest"; then
      ok "Model $m already downloaded"
    else
      info "Downloading model $m"
      ollama pull "$m" || warn "Could not download $m"
    fi
  done
}

storage_setup() {
  case "$STORAGE_PATH" in
    /Volumes/*)
      local vol; vol="/Volumes/$(echo "$STORAGE_PATH" | cut -d/ -f3)"
      [ -d "$vol" ] || die "External drive $vol is not connected. Connect it or change STORAGE_PATH in nomac.conf."
      ;;
  esac
  mkdir -p "$STORAGE_PATH"
  touch "$STORAGE_PATH/.nomac-storage"
  check_free_space "$STORAGE_PATH" || true
}

write_env() {
  mkdir -p "$NOMAC_HOME" "$NOMAC_STATE" "$NOMAC_LOGS" "$NOMAC_HOME/data/mysql" "$NOMAC_HOME/data/redis" "$NOMAC_HOME/update-shared"
  [ -f "$NOMAC_ENV" ] || { touch "$NOMAC_ENV"; chmod 600 "$NOMAC_ENV"; }
  # Secrets: generated once, never overwritten.
  [ -n "$(env_get APP_KEY)" ]             || env_set APP_KEY "$(openssl rand -hex 24)"
  [ -n "$(env_get DB_PASSWORD)" ]         || env_set DB_PASSWORD "$(openssl rand -hex 16)"
  [ -n "$(env_get MYSQL_ROOT_PASSWORD)" ] || env_set MYSQL_ROOT_PASSWORD "$(openssl rand -hex 16)"
  env_set NOMAC_HOME "$NOMAC_HOME"
  env_set STORAGE_PATH "$STORAGE_PATH"
  env_set NOMAD_PORT "$NOMAD_PORT"
  env_set NOMAD_URL "$NOMAD_URL"
  env_set DOZZLE_PORT "$DOZZLE_PORT"
  cp "$NOMAC_REPO/compose/compose.yaml" "$NOMAC_COMPOSE"
  [ -f "$NOMAC_HOME/update-shared/update-status" ] || {
    printf '{"stage":"idle","progress":0,"message":"Ready for update requests","timestamp":"%s"}\n' "$(now_iso)" \
      > "$NOMAC_HOME/update-shared/update-status"; }
}

api_post() {
  curl -fsS -m 60 -X POST -H 'Content-Type: application/json' -d "$2" "http://localhost:$NOMAD_PORT$1"
}

connect_ai() {
  local url="http://host.docker.internal:${OLLAMA_BIND##*:}"
  if api_post /api/ollama/configure-remote "{\"remoteUrl\":\"$url\"}" >/dev/null 2>&1; then
    ok "NOMAD's AI Assistant connected to native Ollama ($url)"
  else
    warn "Could not connect NOMAD to Ollama automatically. In NOMAD: Settings → AI Assistant → remote URL $url"
  fi
}

# Extract configured countries once; tracked in state so re-installs don't repeat.
request_maps() {
  local countries="${1:-$MAP_COUNTRIES}" zoom="${2:-$MAP_MAX_ZOOM}" key json c resp
  [ -n "$countries" ] || return 0
  key="$(echo "$countries" | tr ' ' '\n' | sort | tr '\n' ' ')z$zoom"
  if [ "${3:-}" != "force" ] && grep -qxF "$key" "$NOMAC_STATE/maps-requested" 2>/dev/null; then
    ok "Maps for $countries (zoom $zoom) already requested"
    return 0
  fi
  json="["; for c in $countries; do json="$json\"$c\","; done; json="${json%,}]"
  if resp="$(api_post /api/maps/extract "{\"countries\":$json,\"maxzoom\":$zoom}" 2>&1)"; then
    echo "$key" >> "$NOMAC_STATE/maps-requested"
    ok "Map download started for $countries (zoom $zoom) — progress shows in NOMAD"
  else
    warn "Map request failed: $resp"
  fi
}

power_prompt() {
  [ -f "$NOMAC_STATE/asked-power" ] && return 0
  touch "$NOMAC_STATE/asked-power"
  if ask "Set this Mac to never sleep and to restart by itself after a power cut? Needs your password." y; then
    cmd_power || true
  else
    echo "   You can do this later with: ./nomac power"
  fi
}

cmd_install() {
  [ "$(uname -s)" = "Darwin" ] || die "nomac runs on macOS."
  [ "$(uname -m)" = "arm64" ] || die "nomac targets Apple Silicon Macs."
  first_run_questions
  load_config
  ensure_brew
  brew_install git jq
  storage_setup
  write_env
  ensure_docker
  ensure_ollama
  pull_models

  local v; v="$(resolve_version "$NOMAD_VERSION")"
  build_image "$v"
  info "Starting NOMAD"
  apply_version "$v"
  wait_for nomad_ready 300 || die "NOMAD did not become healthy. Check: ./nomac logs"
  ok "NOMAD $v is up"

  write_updater_agent;  load_agent updater
  write_diskinfo_agent; load_agent diskinfo
  connect_ai
  request_maps
  ( cmd_content ) || warn "Library download not started — see above, then run ./nomac content"
  power_prompt

  echo
  ok "${C_BLD}Project NOMAD is ready: $NOMAD_URL${C_OFF}"
  cat <<EOF

  Next steps in NOMAD:
    • Library downloads (PROFILE/LIBRARY in nomac.conf) are running — watch them in NOMAD
    • Easy Setup: add Kolibri courses or anything else you want
    • Settings → Updates: turn on automatic updates (core, apps, content) and pick a window
    • The AI Assistant is already connected; add or switch models in its settings

  ./nomac status     what's running and how much space is used
  ./nomac drill      once downloads finish: check everything works offline
  ./nomac help       all commands
EOF
}

cmd_start() {
  load_config
  storage_setup
  write_env
  docker_ready || ensure_docker
  ollama_ready || load_agent ollama
  compose up -d --remove-orphans
  wait_for nomad_ready 180 && ok "NOMAD is up: $NOMAD_URL" || warn "NOMAD is still starting; check ./nomac logs"
}

cmd_stop() {
  load_config
  compose down
  ok "NOMAD stopped (apps it installed, e.g. Kiwix, keep running: ./nomac stop --all to stop those too)"
  if [ "${1:-}" = "--all" ]; then
    docker ps -q --filter name=nomad_ | xargs -r docker stop >/dev/null
    launchctl bootout "gui/$(id -u)/$AGENT_PREFIX.ollama" >/dev/null 2>&1 || true
    ok "All NOMAD containers and Ollama stopped (./nomac start brings them back)"
  fi
}

cmd_uninstall() {
  load_config
  ask "Remove NOMAD containers, images and background jobs?" n || exit 0
  compose down --remove-orphans 2>/dev/null || true
  docker ps -aq --filter name=nomad_ | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker images -q "$IMAGE_REPO" | xargs -r docker rmi -f >/dev/null 2>&1 || true
  unload_agent updater; unload_agent diskinfo; unload_agent ollama
  ok "Containers, images and background jobs removed"
  if ask "Also delete NOMAD's database and settings ($NOMAC_HOME)?" n; then
    rm -rf "$NOMAC_HOME"; ok "Deleted $NOMAC_HOME"
  fi
  if ask "Also delete ALL offline content in $STORAGE_PATH?" n; then
    rm -rf "$STORAGE_PATH"; ok "Deleted $STORAGE_PATH"
  fi
  echo "Kept: Ollama and its models (brew uninstall ollama; rm -rf ~/.ollama), Docker runtime."
}
