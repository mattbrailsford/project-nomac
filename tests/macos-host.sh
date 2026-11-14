#!/bin/bash
# macOS host test (CI: GitHub's Apple Silicon runner, which has no Docker).
# Runs under the stock /bin/bash 3.2 and BSD tools and covers everything
# nomac does on the Mac outside of containers:
#   config handling, secrets/.env, Homebrew Ollama as a launchd job, model
#   download + a reply, plist validity, the updater job reacting to NOMAD's
#   request file, and the disk report from real macOS df.
set -eo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
W="${RUNNER_TEMP:-/tmp}/nomac-mac"
rm -rf "$W"; mkdir -p "$W"
export NOMAC_HOME="$W/home" NOMAC_CONF="$W/nomac.conf"
NOMAC_REPO="$REPO"
NOMAC="$REPO/nomac"
MODEL="qwen3:0.6b"

. "$REPO/lib/common.sh"; . "$REPO/lib/build.sh"; . "$REPO/lib/update.sh"; . "$REPO/lib/host.sh"; . "$REPO/lib/install.sh"

PASS=0
pass() { ok "PASS: $*"; PASS=$((PASS + 1)); }
fail() { die "FAIL: $*"; }
step() { echo; info "${C_BLD}$*${C_OFF}"; }
cleanup() { for j in ollama updater diskinfo; do unload_agent "$j"; done; }
trap cleanup EXIT

step "0. Platform"
echo "  $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m), $BASH_VERSION"
[ "$(uname -m)" = "arm64" ] || fail "expected Apple Silicon runner"
case "$BASH_VERSION" in 3.2*) pass "running under macOS's bash 3.2" ;; *) warn "not bash 3.2: $BASH_VERSION" ;; esac
for f in "$NOMAC" "$REPO"/lib/*.sh "$REPO"/tests/*.sh; do /bin/bash -n "$f" || fail "syntax: $f"; done
pass "all scripts parse with /bin/bash"

step "1. Config file handling (BSD awk/sed)"
mkdir -p "$W/repo"; cp "$REPO/nomac.conf.example" "$W/repo/nomac.conf"
( NOMAC_REPO="$W/repo"; conf_set STORAGE_PATH "/Volumes/NomadSSD/nomad"; conf_set MAP_COUNTRIES "GB IE" )
grep -qx 'STORAGE_PATH="/Volumes/NomadSSD/nomad"' "$W/repo/nomac.conf" || fail "conf_set STORAGE_PATH"
grep -qx 'MAP_COUNTRIES="GB IE"' "$W/repo/nomac.conf" || fail "conf_set MAP_COUNTRIES"
pass "conf_set rewrites nomac.conf"

cat > "$NOMAC_CONF" <<EOF
STORAGE_PATH="$W/storage"
NOMAD_VERSION="latest"
OLLAMA_BIND="0.0.0.0:11434"
MODELS="$MODEL"
MIN_FREE_GB=5
EOF
load_config
storage_setup
write_env
for k in APP_KEY DB_PASSWORD MYSQL_ROOT_PASSWORD NOMAC_HOME STORAGE_PATH; do
  [ -n "$(env_get $k)" ] || fail ".env missing $k"
done
[ "$(stat -f %Lp "$NOMAC_ENV")" = "600" ] || fail ".env permissions not 600"
key1="$(env_get APP_KEY)"; write_env; [ "$(env_get APP_KEY)" = "$key1" ] || fail "secrets regenerated on re-run"
pass ".env written once with private permissions"

v="$(latest_upstream_version)"; is_semver "$v" || fail "latest version lookup: '$v'"
is_semver 'v1.2.3$(id)' && fail "is_semver accepted an injection"
pass "upstream release lookup ($v) and tag validation"
[ -n "$(free_gb "$STORAGE_PATH")" ] || fail "free_gb"
pass "free space: $(free_gb "$STORAGE_PATH") GB"

step "2. Ollama via Homebrew as a launchd job"
ensure_ollama
launchctl print "gui/$(id -u)/$AGENT_PREFIX.ollama" | grep -E 'state|OLLAMA_' | sed 's/^/  /' || true
pass "Ollama running from launchd on $OLLAMA_BIND"
pull_models
out="$(curl -fsS -m 600 "$(ollama_url)/api/generate" -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with just OK\",\"stream\":false,\"think\":false}")"
echo "  reply: $(echo "$out" | jq -r .response | head -c 200)"
ollama ps | sed 's/^/  /'
pass "model downloaded and answered"
ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [ -n "$ip" ] && curl -fsS -m 5 "http://$ip:11434/api/version" >/dev/null; then
  pass "Ollama reachable on the LAN address ($ip) — as containers will reach it"
else
  warn "could not check Ollama on a LAN address"
fi

step "3. launchd plists"
write_updater_agent; write_diskinfo_agent
for j in ollama updater diskinfo; do plutil -lint "$(agent_path $j)" >/dev/null || fail "invalid plist: $j"; done
pass "all three plists are valid"

step "4. Updater job reacts to NOMAD's request file"
load_agent updater
sleep 3
echo '{"target_tag":"v9.9.9;$(touch /tmp/pwned)","requester":"ci"}' > "$REQUEST_FILE"
i=0
until grep -q "Invalid update target" "$STATUS_FILE" 2>/dev/null || grep -q "Rejected update request" "$UPDATE_LOG" 2>/dev/null; do
  i=$((i + 2)); [ "$i" -ge 90 ] && { cat "$NOMAC_LOGS/updater.log" 2>/dev/null; fail "updater job did not handle the request"; }
  sleep 2
done
[ ! -e /tmp/pwned ] || fail "request contents were executed"
[ ! -f "$REQUEST_FILE" ] || fail "request file not consumed"
cat "$UPDATE_LOG" | sed 's/^/  /'
pass "launchd WatchPaths ran the handler, which rejected a malicious tag"

step "5. Disk report job (real macOS df)"
load_agent diskinfo
i=0
until [ -s "$STORAGE_PATH/nomad-disk-info.json" ] && jq -e '.fsSize | length > 0' "$STORAGE_PATH/nomad-disk-info.json" >/dev/null 2>&1; do
  i=$((i + 2)); [ "$i" -ge 60 ] && { cat "$NOMAC_LOGS/diskinfo.log" 2>/dev/null; fail "disk report not written"; }
  sleep 2
done
jq . "$STORAGE_PATH/nomad-disk-info.json"
jq -e '[.fsSize[].mount] | index("/System/Volumes/Data") != null' "$STORAGE_PATH/nomad-disk-info.json" >/dev/null || fail "internal data volume missing"
jq -e '.diskLayout.blockdevices | all(.type == "disk")' "$STORAGE_PATH/nomad-disk-info.json" >/dev/null || fail "blockdevices malformed"
pass "disk report written by launchd job in NOMAD's format"

step "6. CLI without Docker"
"$NOMAC" help >/dev/null
"$NOMAC" status || fail "status crashed"
pass "status works when Docker is absent"

echo; ok "${C_BLD}All $PASS checks passed${C_OFF}"
