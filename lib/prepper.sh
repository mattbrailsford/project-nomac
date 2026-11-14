# shellcheck shell=bash
# Resilience: power-loss recovery (`power`), readiness check (`drill`) and
# copying the essentials to a phone/tablet (`export-phone`).

is_macos() { [ "$(uname -s)" = "Darwin" ]; }

file_bytes() { wc -c < "$1" | tr -d ' '; }

# --------------------------------------------------------------- power ------
cmd_power() {
  load_config
  is_macos || die "power settings are macOS-only"
  info "Power-loss recovery (needs your password)"
  # sleep 0: stay reachable; autorestart 1: boot when power returns;
  # womp 1: wake for network access. The display can still sleep.
  sudo pmset -a sleep 0 disksleep 0 autorestart 1 womp 1 \
    && ok "Mac set to never sleep and to start up automatically after a power cut"

  case "$DOCKER_RUNTIME" in
    orbstack)
      if osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q OrbStack; then
        ok "OrbStack opens at login"
      elif osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/OrbStack.app", hidden:true}' >/dev/null 2>&1; then
        ok "OrbStack added to Login Items"
      else
        warn "Add OrbStack to System Settings → General → Login Items (or enable 'Start at login' in OrbStack settings)"
      fi
      ;;
    colima) brew services start colima >/dev/null 2>&1 && ok "Colima starts at login" ;;
  esac
  autologin_advice
}

autologin_advice() {
  local user fv
  user="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
  fv="$(fdesetup status 2>/dev/null || true)"
  if [ -n "$user" ]; then
    ok "Automatic login is on ($user): NOMAD comes back by itself after a power cut"
    return 0
  fi
  warn "Automatic login is off. After a power cut the Mac boots to the login screen and"
  warn "NOMAD stays down until someone logs in (Ollama and Docker run per user)."
  case "$fv" in
    *"On"*) warn "FileVault is on, which rules out automatic login. Choose: keep FileVault (safer if the Mac is stolen; log in after outages) or turn it off and enable automatic login." ;;
    *) warn "To fix: System Settings → Users & Groups → Automatically log in as → your user." ;;
  esac
  return 1
}

# --------------------------------------------------------------- drill ------
D_PASS=0; D_WARN=0; D_FAIL=0
d_pass() { ok "$*"; D_PASS=$((D_PASS + 1)); }
d_warn() { warn "$*"; D_WARN=$((D_WARN + 1)); }
d_fail() { printf '%s ✗%s %s\n' "$C_RED" "$C_OFF" "$*"; D_FAIL=$((D_FAIL + 1)); }

latest_zim() { ls -t "$(zim_dir)/${1}_"*.zim 2>/dev/null | head -n 1 || true; }

# General Wikipedia editions on disk, largest first (excludes WikiMed etc.).
general_wikipedia() { ls -S "$(zim_dir)"/wikipedia_en_all_*.zim "$(zim_dir)"/wikipedia_en_top_*.zim 2>/dev/null || true; }

kiwix_port() { docker port nomad_kiwix_server 2>/dev/null | head -n 1 | sed 's/.*://' || true; }

cmd_drill() {
  load_config; apply_profile_defaults
  local id f port stem m model t0 secs out wanted=0 found=0 app plan_ids wiki
  echo "${C_BLD}NOMAD readiness drill${C_OFF} — best run with the internet unplugged"
  if online; then d_warn "Internet is connected; for a real test unplug it and run ./nomac drill again"
  else d_pass "Running with no internet"; fi

  echo; info "Core"
  nomad_ready && d_pass "NOMAD responds at $NOMAD_URL" || d_fail "NOMAD not responding"
  ollama_ready && d_pass "Ollama running" || d_fail "Ollama not running"

  echo; info "Essential library"
  port="$(kiwix_port)"
  [ -n "$port" ] && d_pass "Information Library (Kiwix) on port $port" || d_fail "Kiwix not running"
  plan_ids="$(plan_library 2>/dev/null | cut -f1 || true)"
  for id in $ESSENTIAL_IDS; do
    # Only check what the configured plan includes (or what is on disk anyway).
    f="$(latest_zim "$id")"
    if [ -z "$f" ]; then
      if echo "$plan_ids" | grep -qx "$id"; then
        wanted=$((wanted + 1)); d_fail "$id missing (run ./nomac content while online)"
      fi
      continue
    fi
    wanted=$((wanted + 1))
    stem="$(basename "$f" .zim)"
    if [ -n "$port" ] && curl -fsSL -m 20 -o /dev/null "http://localhost:$port/content/$stem/"; then
      found=$((found + 1)); d_pass "$stem opens"
    else
      d_fail "$stem is on disk but does not open in Kiwix"
    fi
  done
  [ "$wanted" -eq 0 ] && d_warn "No essential references found or planned (set PROFILE=\"prepper\")"
  wiki="$(general_wikipedia | head -n 1)"
  if [ -n "$wiki" ]; then
    d_pass "Wikipedia: $(basename "$wiki" .zim)"
  else
    d_warn "No general Wikipedia"
  fi

  echo; info "Maps"
  if [ -n "${MAP_COUNTRIES:-}" ]; then
    m="$(find "$STORAGE_PATH/maps" -name '*_z*.pmtiles' 2>/dev/null | head -n 5 || true)"
    [ -n "$m" ] && d_pass "Map extracts: $(echo "$m" | xargs -n1 basename | tr '\n' ' ')" || d_fail "No map extract for $MAP_COUNTRIES"
  fi

  echo; info "AI assistant"
  model="$(ollama list 2>/dev/null | awk 'NR>1 && $1 !~ /embed/ {print $1; exit}' || true)"
  if [ -z "$model" ]; then d_fail "No chat model installed"
  else
    t0=$(date +%s)
    out="$(curl -fsS -m 300 -H 'Content-Type: application/json' -X POST \
      -d "{\"model\":\"$model\",\"stream\":false,\"think\":false,\"messages\":[{\"role\":\"user\",\"content\":\"In one sentence: how can I make stream water safe to drink?\"}]}" \
      "http://localhost:$NOMAD_PORT/api/ollama/chat" 2>/dev/null || true)"
    secs=$(( $(date +%s) - t0 ))
    if [ -n "$out" ]; then
      d_pass "$model answered through NOMAD in ${secs}s"
      echo "     \"$(echo "$out" | jq -r '.message.content // empty' 2>/dev/null | tr '\n' ' ' | cut -c1-160)\""
    else d_fail "$model did not answer through NOMAD"; fi
  fi
  ollama list 2>/dev/null | awk '{print $1}' | grep -qxF "$EMBEDDING_MODEL" \
    && d_pass "Knowledge-base search model present" || d_fail "$EMBEDDING_MODEL missing (document search won't work)"

  if [ -n "$APPS" ]; then
    echo; info "Apps"
    for app in $APPS; do
      if docker ps --format '{{.Names}}' | grep -qx "$app"; then d_pass "$app running"; else d_fail "$app not running"; fi
    done
  fi

  echo; info "Storage"
  check_free_space "$STORAGE_PATH" >/dev/null 2>&1 && d_pass "$(free_gb "$STORAGE_PATH") GB free" || d_warn "Low space: $(free_gb "$STORAGE_PATH") GB free"

  echo; info "Power and restart"
  if is_macos; then
    pmset -g 2>/dev/null | grep -Eq '^ *autorestart +1' && d_pass "Starts up after a power cut" || d_fail "Won't restart after a power cut (run ./nomac power)"
    pmset -g 2>/dev/null | grep -Eq '^ *sleep +0' && d_pass "System sleep disabled" || d_warn "Mac may sleep (run ./nomac power)"
    if pmset -g ps 2>/dev/null | grep -qi 'UPS'; then d_pass "UPS detected"; else d_warn "No UPS/power station reported over USB"; fi
    autologin_advice >/dev/null 2>&1 && d_pass "Automatic login on" || d_warn "Automatic login off: NOMAD waits for a login after a power cut"
  else
    d_warn "Power checks are macOS-only"
  fi

  echo
  echo "${C_BLD}Result:${C_OFF} $D_PASS passed, $D_WARN warnings, $D_FAIL failed"
  [ "$D_FAIL" -eq 0 ]
}

# --------------------------------------------------------- export-phone -----
cmd_export_phone() {
  load_config; apply_profile_defaults
  local dest="" max_gb=20 used=0 id f size budget n=0 wiki=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-gb) max_gb="$2"; shift 2 ;;
      *) dest="$1"; shift ;;
    esac
  done
  dest="${dest:-$HOME/Desktop/NOMAD-for-phone}"
  budget=$((max_gb * 1024 * 1024 * 1024))
  mkdir -p "$dest"
  info "Copying essential references to $dest (up to $max_gb GB)"
  for id in $ESSENTIAL_IDS WIKIPEDIA; do
    if [ "$id" = "WIKIPEDIA" ]; then
      # Largest general Wikipedia that still fits.
      f=""
      for wiki in $(general_wikipedia); do
        if [ $((used + $(file_bytes "$wiki"))) -le "$budget" ]; then f="$wiki"; break; fi
      done
      [ -n "$f" ] || { [ -n "$(general_wikipedia)" ] && warn "No Wikipedia edition fits in the remaining space"; continue; }
    else
      f="$(latest_zim "$id")"
    fi
    [ -n "$f" ] && [ -f "$f" ] || continue
    size="$(file_bytes "$f")"
    if [ $((used + size)) -gt "$budget" ]; then
      warn "Skipping $(basename "$f") ($((size / 1048576)) MB): over the $max_gb GB limit"
      continue
    fi
    if [ ! -f "$dest/$(basename "$f")" ]; then
      # APFS clone when on the same volume (instant, no extra space), else copy.
      cp -c "$f" "$dest/" 2>/dev/null || cp "$f" "$dest/"
    fi
    used=$((used + size)); n=$((n + 1))
    ok "$(basename "$f") ($((size / 1048576)) MB)"
  done
  [ "$n" -gt 0 ] || die "No library files found yet in $(zim_dir) — run ./nomac content first."
  cat > "$dest/README.txt" <<EOF
NOMAD essentials for a phone or tablet — $(date '+%Y-%m-%d')

These .zim files open in the free Kiwix app (iOS, iPadOS, Android), with no
internet and without the Mac.

  iPhone/iPad: AirDrop the files, or copy them via Finder (phone → Files →
               Kiwix), then in Kiwix: Library → Open files.
  Android:     copy over USB into Download/ or the SD card, then in Kiwix:
               Library → Device.

Maps: install Organic Maps and download the UK map in that app; NOMAD's map
files are not readable by phone map apps.

Refresh this folder every few months: ./nomac export-phone
EOF
  ok "$n files, $((used / 1048576)) MB in $dest — see README.txt there for how to load them"
}
