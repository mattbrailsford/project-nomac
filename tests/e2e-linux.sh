#!/bin/bash
# End-to-end test on an arm64 Linux machine with Docker and a native Ollama
# listening on 0.0.0.0:11434 (CI: ubuntu-24.04-arm). Exercises everything
# except the macOS-only pieces (Homebrew, OrbStack, launchd), which
# tests/macos-host.sh covers.
#
#   build NOMAD (previous release) -> start -> connect AI -> two models, chat
#   with each -> disk report -> UK map extract -> library + apps preset ->
#   drill -> phone export -> update via NOMAD's own
#   Update button to the latest release -> rollback
set -eo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
W="${RUNNER_TEMP:-/tmp}/nomac-e2e"
rm -rf "$W"; mkdir -p "$W"
export NOMAC_HOME="$W/home" NOMAC_CONF="$W/nomac.conf" NOMAC_PLATFORM="${NOMAC_PLATFORM:-linux/arm64}"
NOMAC_REPO="$REPO"
NOMAC="$REPO/nomac"
MODEL_A="qwen3:0.6b"
MODEL_B="gemma3:270m"

. "$REPO/lib/common.sh"; . "$REPO/lib/build.sh"; . "$REPO/lib/update.sh"; . "$REPO/lib/host.sh"; . "$REPO/lib/install.sh"; . "$REPO/lib/content.sh"; . "$REPO/lib/prepper.sh"

LATEST="$(latest_upstream_version)"
PREV="$(git ls-remote --tags --refs "$UPSTREAM_URL" 'v*' | sed 's|.*refs/tags/v||' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 2 | head -n 1)"
[ -n "$LATEST" ] && [ -n "$PREV" ] && [ "$LATEST" != "$PREV" ] || die "Could not determine releases"

cat > "$NOMAC_CONF" <<EOF
STORAGE_PATH="$W/storage"
NOMAD_VERSION="$PREV"
NOMAD_PORT=8080
DOZZLE=false
OLLAMA_BIND="0.0.0.0:11434"
MODELS="$MODEL_A $MODEL_B"
MAP_COUNTRIES="GB"
MAP_MAX_ZOOM=6
MIN_FREE_GB=5
# Small stand-in for PROFILE="prepper" so CI stays quick.
WIKIPEDIA="top-mini"
LIBRARY="medicine:essential agriculture:essential"
APPS="nomad_kiwix_server nomad_vaultwarden"
EOF
load_config

PASS=0
pass() { ok "PASS: $*"; PASS=$((PASS + 1)); }
fail() { die "FAIL: $*"; }
# api PATH [JSON_BODY] [TIMEOUT] — GET without a body, POST with one.
api() {
  if [ -n "${2:-}" ]; then
    curl -fsS -m "${3:-60}" -H 'Content-Type: application/json' -X POST -d "$2" "http://localhost:$NOMAD_PORT$1"
  else
    curl -fsS -m "${3:-60}" "http://localhost:$NOMAD_PORT$1"
  fi
}
admin_version() { docker exec nomad_admin cat /app/version.json | jq -r .version; }
step() { echo; info "${C_BLD}$*${C_OFF}"; }

# ------------------------------------------------------------------------
step "1. Build NOMAD $PREV (latest is $LATEST) for $NOMAC_PLATFORM and start it"
storage_setup
write_env
build_image "$PREV"
docker image inspect -f '{{.Architecture}}' "$IMAGE_REPO:$PREV" | grep -qx arm64 || fail "image is not arm64"
pass "built $IMAGE_REPO:$PREV (arm64)"
env_set NOMAD_VERSION "$PREV"
"$NOMAC" start
nomad_ready || fail "NOMAD not healthy"
[ "$(admin_version)" = "$PREV" ] || fail "admin reports $(admin_version), expected $PREV"
pass "NOMAD $PREV healthy"

# ------------------------------------------------------------------------
step "2. Models and AI connection (native Ollama via host.docker.internal)"
ollama_ready || fail "Ollama not running on host"
pull_models
connect_ai
api /api/ollama/remote-status | tee /dev/stderr | jq -e '.configured and .connected' >/dev/null || fail "remote Ollama not connected"
pass "NOMAD connected to host Ollama"
installed="$(api /api/ollama/installed-models)"
for m in "$MODEL_A" "$MODEL_B"; do
  echo "$installed" | grep -q "\"$m\"" || fail "NOMAD does not list model $m: $installed"
done
# NOMAD hides embedding models from its chat list by design; check Ollama.
ollama list | awk 'NR>1{print $1}' | grep -qxF "$EMBEDDING_MODEL" || fail "embedding model missing"
pass "NOMAD lists both chat models; embedding model present in Ollama"

# ------------------------------------------------------------------------
step "3. Chat through NOMAD with each model (model switching)"
for m in "$MODEL_A" "$MODEL_B"; do
  out="$(api /api/ollama/chat "{\"model\":\"$m\",\"stream\":false,\"think\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with just the word OK.\"}]}" 300)" \
    || fail "chat with $m failed"
  echo "  $m -> $(echo "$out" | head -c 300)"
  [ -n "$out" ] || fail "empty reply from $m"
  ollama ps | awk 'NR>1{print "  loaded: "$1}'
  ollama ps | awk 'NR>1{print $1}' | grep -qx "$m" || fail "$m is not the loaded model after chatting"
done
[ "$(ollama ps | awk 'NR>1' | wc -l | tr -d ' ')" -le 1 ] || warn "more than one model loaded"
pass "chatted with $MODEL_A then $MODEL_B through NOMAD"

# ------------------------------------------------------------------------
step "4. Disk report (replaces upstream's disk-collector sidecar)"
"$NOMAC" _disk-info
jq -e '.fsSize | length > 0' "$STORAGE_PATH/nomad-disk-info.json" >/dev/null || fail "disk report empty"
api /api/system/info | jq -e '.disk | length > 0' >/dev/null || fail "NOMAD did not read the disk report"
pass "NOMAD shows disks from nomac's report"

# ------------------------------------------------------------------------
step "5. UK map extract (zoom 6)"
"$NOMAC" maps GB --zoom 6
i=0
until find "$STORAGE_PATH" -name '*_z6.pmtiles' -size +10k 2>/dev/null | grep -q .; do
  i=$((i + 10)); [ "$i" -ge 900 ] && fail "UK map extract did not appear within 15 minutes"
  sleep 10
done
find "$STORAGE_PATH" -name '*_z6.pmtiles' -exec ls -lh {} \;
pass "UK map extract downloaded"

# ------------------------------------------------------------------------
step "5b. Library and apps preset (nomac content)"
"$NOMAC" content
i=0
# Count with grep -c (reads everything): grep -q would exit early, break the
# pipe and, under pipefail, look like "nothing missing".
missing() { "$NOMAC" content --dry-run 2>/dev/null | grep -c ' + ' || true; }
until [ "$(missing)" = "0" ]; do
  i=$((i + 15)); [ "$i" -ge 1800 ] && { "$NOMAC" content --dry-run; fail "library downloads did not finish in 30 minutes"; }
  sleep 15
done
"$NOMAC" content --dry-run
for app in nomad_kiwix_server nomad_vaultwarden; do
  docker ps --format '{{.Names}}' | grep -qx "$app" || fail "$app not running"
done
pass "Wikipedia, medicine and agriculture sets downloaded; Kiwix and Vaultwarden running"

step "5c. Readiness drill"
"$NOMAC" drill || fail "drill reported failures"
pass "drill passed (library opens in Kiwix, AI answers, maps and apps present)"

step "5d. Phone export"
"$NOMAC" export-phone "$W/phone" --max-gb 1
[ -f "$W/phone/README.txt" ] || fail "export README missing"
n="$(find "$W/phone" -name '*.zim' | wc -l | tr -d ' ')"
[ "$n" -ge 5 ] || fail "expected the 4 medical references plus Wikipedia, got $n files"
find "$W/phone" -name 'wikipedia_en_top_*.zim' | grep -q . || fail "Wikipedia not exported"
pass "exported $n references for the Kiwix phone app"

# ------------------------------------------------------------------------
step "6. Update $PREV -> $LATEST via NOMAD's own Update API"
# Stand-in for launchd's WatchPaths job on the Mac.
( while :; do "$NOMAC" _handle-update-request >> "$W/handler.log" 2>&1 || true; sleep 2; done ) &
WATCHER=$!
trap 'kill $WATCHER 2>/dev/null || true' EXIT
api "/api/system/latest-version?force=true" | tee /dev/stderr | jq -e '.success != false' >/dev/null || fail "version check failed"
api /api/system/update '{}' | tee /dev/stderr | jq -e '.success' >/dev/null || fail "NOMAD refused the update request"
i=0; stage=""
while :; do
  stage="$(jq -r .stage "$STATUS_FILE" 2>/dev/null || true)"
  [ "$stage" = "complete" ] && break
  [ "$stage" = "error" ] && { cat "$UPDATE_LOG"; fail "update reported error"; }
  i=$((i + 10)); [ "$i" -ge 2700 ] && { cat "$UPDATE_LOG"; fail "update did not complete in 45 minutes (stage: $stage)"; }
  sleep 10
done
wait_for nomad_ready 300 || fail "NOMAD not healthy after update"
[ "$(admin_version)" = "$LATEST" ] || fail "admin reports $(admin_version) after update, expected $LATEST"
[ "$(current_version)" = "$LATEST" ] && [ "$(cat "$NOMAC_STATE/previous_version")" = "$PREV" ] || fail "nomac state wrong after update"
api /api/system/update/status | jq .
api /api/ollama/remote-status | jq -e '.connected' >/dev/null || fail "AI connection lost after update"
pass "updated to $LATEST through NOMAD's Update API; AI still connected"
kill $WATCHER 2>/dev/null || true

# ------------------------------------------------------------------------
step "7. Rollback to $PREV"
"$NOMAC" rollback
wait_for nomad_ready 300 || fail "NOMAD not healthy after rollback"
[ "$(admin_version)" = "$PREV" ] || fail "admin reports $(admin_version) after rollback"
pass "rolled back to $PREV"

# ------------------------------------------------------------------------
step "8. status / doctor / cleanup"
"$NOMAC" status
"$NOMAC" doctor || warn "doctor reported issues (expected on Linux: not Apple Silicon)"
"$NOMAC" cleanup >/dev/null
pass "status, doctor and cleanup ran"

echo; ok "${C_BLD}All $PASS checks passed${C_OFF}"
