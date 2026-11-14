# shellcheck shell=bash
# macOS launchd jobs (per-user LaunchAgents) and the disk-info writer.
#   com.nomac.ollama    native Ollama server (Metal GPU)
#   com.nomac.updater   answers NOMAD's update requests (see lib/update.sh)
#   com.nomac.diskinfo  writes nomad-disk-info.json for NOMAD's storage screen

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

agent_path() { echo "$LAUNCH_AGENTS/$AGENT_PREFIX.$1.plist"; }

load_agent() {
  local label="$AGENT_PREFIX.$1" plist
  plist="$(agent_path "$1")"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

unload_agent() {
  launchctl bootout "gui/$(id -u)/$AGENT_PREFIX.$1" >/dev/null 2>&1 || true
  rm -f "$(agent_path "$1")"
}

write_ollama_agent() {
  local bin models_xml=""
  bin="$(command -v ollama)" || die "ollama not found"
  if [ -n "${OLLAMA_MODELS_DIR:-}" ]; then
    mkdir -p "$OLLAMA_MODELS_DIR"
    models_xml="<key>OLLAMA_MODELS</key><string>$(xml_escape "$OLLAMA_MODELS_DIR")</string>"
  fi
  mkdir -p "$LAUNCH_AGENTS" "$NOMAC_LOGS"
  cat > "$(agent_path ollama)" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$AGENT_PREFIX.ollama</string>
  <key>ProgramArguments</key><array><string>$(xml_escape "$bin")</string><string>serve</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>OLLAMA_HOST</key><string>$(xml_escape "$OLLAMA_BIND")</string>
    <key>OLLAMA_KEEP_ALIVE</key><string>$(xml_escape "$OLLAMA_KEEP_ALIVE")</string>
    <key>OLLAMA_MAX_LOADED_MODELS</key><string>1</string>
    <key>OLLAMA_NUM_PARALLEL</key><string>1</string>
    <key>OLLAMA_FLASH_ATTENTION</key><string>1</string>
    $models_xml
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$(xml_escape "$NOMAC_LOGS/ollama.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$NOMAC_LOGS/ollama.log")</string>
</dict></plist>
EOF
}

write_updater_agent() {
  mkdir -p "$LAUNCH_AGENTS" "$NOMAC_LOGS" "$NOMAC_HOME/update-shared"
  cat > "$(agent_path updater)" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$AGENT_PREFIX.updater</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$(xml_escape "$NOMAC_REPO/nomac")</string><string>_handle-update-request</string>
  </array>
  <key>WatchPaths</key><array><string>$(xml_escape "$NOMAC_HOME/update-shared")</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$(xml_escape "$NOMAC_LOGS/updater.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$NOMAC_LOGS/updater.log")</string>
</dict></plist>
EOF
}

write_diskinfo_agent() {
  mkdir -p "$LAUNCH_AGENTS" "$NOMAC_LOGS"
  cat > "$(agent_path diskinfo)" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$AGENT_PREFIX.diskinfo</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$(xml_escape "$NOMAC_REPO/nomac")</string><string>_disk-info</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>120</integer>
  <key>StandardOutPath</key><string>$(xml_escape "$NOMAC_LOGS/diskinfo.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$NOMAC_LOGS/diskinfo.log")</string>
</dict></plist>
EOF
}

install_agents() {
  write_ollama_agent;   load_agent ollama
  write_updater_agent;  load_agent updater
  write_diskinfo_agent; load_agent diskinfo
}

# One JSON entry per filesystem we care about, in the shape upstream's
# disk-collector sidecar produces (lsblk-like blockdevices + fsSize). Each
# filesystem is reported as its own "disk" so NOMAD's matcher pairs them.
cmd_disk_info() {
  load_config
  [ -d "$STORAGE_PATH" ] || exit 0
  local out="$STORAGE_PATH/nomad-disk-info.json" mounts m line dev size used avail pct name model tran
  local bd="" fs="" seen=""
  # Data volume of the internal disk, plus wherever storage lives.
  mounts="/System/Volumes/Data $STORAGE_PATH"
  for m in $mounts; do
    line="$(df -k "$m" 2>/dev/null | awk 'NR==2{print $1, $2*1024, $3*1024, $4*1024, $5}')" || continue
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086
    set -- $line
    dev="$1"; size="$2"; used="$3"; avail="$4"; pct="${5%\%}"
    case " $seen " in *" $dev "*) continue ;; esac
    seen="$seen $dev"
    name="${dev#/dev/}"
    model="Internal SSD"; tran="nvme"
    case "$m" in /Volumes/*) model="External: $(echo "$m" | cut -d/ -f3 | tr -d '"\\')"; tran="usb" ;; esac
    [ -n "$bd" ] && bd="$bd,"; [ -n "$fs" ] && fs="$fs,"
    bd="$bd{\"name\":\"$name\",\"size\":$size,\"type\":\"disk\",\"model\":\"$model\",\"serial\":null,\"vendor\":\"\",\"rota\":false,\"tran\":\"$tran\"}"
    fs="$fs{\"fs\":\"$dev\",\"size\":$size,\"used\":$used,\"available\":$avail,\"use\":$pct,\"mount\":\"$m\"}"
  done
  printf '{"diskLayout":{"blockdevices":[%s]},"fsSize":[%s]}\n' "$bd" "$fs" > "$out.tmp" && mv "$out.tmp" "$out"
}
