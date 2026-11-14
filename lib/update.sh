# shellcheck shell=bash
# Core NOMAD updates.
#
# Upstream's admin app decides WHEN to update (manual "Update" button, or the
# opt-in auto-update window in Settings) and writes
#   /app/update-shared/update-request   {"target_tag": "v1.2.3", ...}
# which upstream's Linux sidecar answers by pulling an amd64 image. Here that
# folder is bind-mounted from ~/.nomac/update-shared and a launchd job
# (com.nomac.updater, WatchPaths) runs `nomac _handle-update-request`, which
# rebuilds the arm64 image from source and restarts the stack, writing progress
# to update-status in the format the admin UI reads.

SHARED_DIR="$NOMAC_HOME/update-shared"
REQUEST_FILE="$SHARED_DIR/update-request"
STATUS_FILE="$SHARED_DIR/update-status"
UPDATE_LOG="$SHARED_DIR/update-log"
LOCK_DIR="$NOMAC_HOME/update.lock"

# stage must be one of: idle starting pulling pulled recreating complete error
write_status() {
  local msg
  msg="$(printf '%s' "$3" | tr -d '"\\')"
  printf '{\n  "stage": "%s",\n  "progress": %s,\n  "message": "%s",\n  "timestamp": "%s"\n}\n' \
    "$1" "$2" "$msg" "$(now_iso)" > "$STATUS_FILE.tmp" && mv "$STATUS_FILE.tmp" "$STATUS_FILE"
}

ulog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$UPDATE_LOG"; }

take_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
    return 0
  fi
  # Stale lock (older than 2h)?
  if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null && {
      trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT; return 0; }
  fi
  return 1
}

# Full update to version $1 (no "v"). Used by both the UI request and the CLI.
perform_update() {
  local v="$1" cur
  cur="$(current_version)"
  : > "$UPDATE_LOG"
  ulog "Update requested: $cur -> $v"
  write_status starting 5 "Update to $v initiated"

  if ! online; then
    ulog "No internet connection; skipping."
    write_status error 0 "No internet connection - update skipped"
    return 1
  fi

  write_status pulling 15 "Building NOMAD $v for Apple Silicon (this takes several minutes)..."
  if ! build_image "$v" >> "$UPDATE_LOG" 2>&1; then
    ulog "ERROR: image build failed"
    write_status error 0 "Building NOMAD $v failed - see ~/.nomac/update-shared/update-log"
    return 1
  fi
  compose pull --quiet mysql redis >> "$UPDATE_LOG" 2>&1 || ulog "WARNING: could not refresh mysql/redis images"
  write_status pulled 60 "Build complete"

  write_status recreating 70 "Restarting NOMAD on $v..."
  if ! apply_version "$v" >> "$UPDATE_LOG" 2>&1; then
    ulog "ERROR: restart failed; reverting to $cur"
    [ -n "$cur" ] && apply_version "$cur" >> "$UPDATE_LOG" 2>&1
    write_status error 0 "Restart on $v failed - reverted to $cur"
    return 1
  fi

  if wait_for nomad_ready 300; then
    ulog "NOMAD $v is healthy"
  else
    ulog "WARNING: NOMAD $v did not report healthy within 5 minutes (run: nomac rollback)"
  fi

  if [ "${AUTO_UPGRADE_OLLAMA:-true}" = "true" ]; then
    upgrade_ollama >> "$UPDATE_LOG" 2>&1 || ulog "WARNING: Ollama upgrade failed"
  fi

  prune_images >> "$UPDATE_LOG" 2>&1 || true
  write_status complete 100 "Updated to $v"
  ulog "Update complete"
}

upgrade_ollama() {
  command -v brew >/dev/null || return 0
  if brew outdated --quiet ollama 2>/dev/null | grep -q ollama; then
    ulog "Upgrading Ollama"
    brew upgrade ollama && launchctl kickstart -k "gui/$(id -u)/$AGENT_PREFIX.ollama"
  fi
}

# launchd entry point. Fires on any change in update-shared/, so exit quietly
# unless a request is actually waiting.
cmd_handle_update_request() {
  [ -f "$REQUEST_FILE" ] || exit 0
  take_lock || exit 0
  load_config
  local req tag
  req="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
  rm -f "$REQUEST_FILE"
  tag="$(printf '%s' "$req" | jq -r '.target_tag // "latest"' 2>/dev/null || echo latest)"
  if [ "$tag" = "latest" ]; then
    tag="$(latest_upstream_version)"
  fi
  if ! is_semver "$tag"; then
    : > "$UPDATE_LOG"; ulog "Rejected update request with invalid tag: $tag"
    write_status error 0 "Invalid update target"
    exit 1
  fi
  perform_update "${tag#v}" || true
  sleep 5
  write_status idle 0 "Ready for update requests"
}

cmd_update() {
  load_config
  local target="${1:-latest}" v cur
  cur="$(current_version)"
  if [ "$target" = "--check" ]; then
    v="$(latest_upstream_version)"
    echo "Installed: ${cur:-none}   Latest upstream: ${v:-unknown}"
    return 0
  fi
  v="$(resolve_version "$target")"
  is_semver "$v" || die "Not a version: $target"
  if [ "$v" = "$cur" ] && [ "${NOMAC_REBUILD:-0}" != "1" ]; then
    ok "Already on $v"; return 0
  fi
  take_lock || die "Another update is running."
  info "Updating NOMAD ${cur:-?} -> $v (progress: tail -f $UPDATE_LOG)"
  if perform_update "$v"; then ok "Updated to $v"; else die "Update failed — see $UPDATE_LOG"; fi
  write_status idle 0 "Ready for update requests"
}
