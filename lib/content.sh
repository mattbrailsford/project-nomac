# shellcheck shell=bash
# Declarative content and apps (nomac.conf: PROFILE, WIKIPEDIA, LIBRARY, APPS).
# Everything is requested through NOMAD's own API, so NOMAD's UI tracks it and
# its content auto-update keeps it current. Sizes come from NOMAD's curated
# collection manifests in the upstream source, so the total is checked against
# free space before anything is downloaded.

# Defaults for PROFILE="prepper" (~80 GB). Explicit settings in nomac.conf win.
PREPPER_WIKIPEDIA="all-nopic"
PREPPER_LIBRARY="medicine:comprehensive survival:standard diy:comprehensive agriculture:standard education:essential"
PREPPER_APPS="nomad_kiwix_server nomad_flatnotes nomad_meshtastic_web nomad_calibreweb nomad_vaultwarden nomad_homebox nomad_filebrowser"

# Most important first: used by `drill` and `export-phone`.
ESSENTIAL_IDS="zimgit-medicine_en nhs.uk_en_medicines wwwnc.cdc.gov_en_all irp.fas.org_en_military-medicine fas-military-medicine_en zimgit-water_en zimgit-food-preparation_en zimgit-knots_en zimgit-post-disaster_en medlineplus.gov_en_all wikipedia_en_medicine_maxi www.ready.gov_en outdoors.stackexchange.com_en_all ifixit_en_all"

apply_profile_defaults() {
  if [ "${PROFILE:-}" = "prepper" ]; then
    WIKIPEDIA="${WIKIPEDIA-$PREPPER_WIKIPEDIA}"
    LIBRARY="${LIBRARY-$PREPPER_LIBRARY}"
    APPS="${APPS-$PREPPER_APPS}"
  fi
  WIKIPEDIA="${WIKIPEDIA:-}"; LIBRARY="${LIBRARY:-}"; APPS="${APPS:-}"
}

# NOMAD reads its curated lists from upstream's main branch at runtime (see
# CollectionManifestService), which can differ from the bundled copy (files
# get renamed). Use the same lists: refreshed daily while online, cached for
# offline use, bundled copy as the last resort.
MANIFEST_BASE="https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/refs/heads/main/collections"

manifest_dir() {
  local cache="$NOMAC_STATE/manifests" bundled="$NOMAC_UPSTREAM/collections" f tmp
  mkdir -p "$cache"
  for f in kiwix-categories.json wikipedia.json; do
    if [ ! -s "$cache/$f" ] || [ -n "$(find "$cache/$f" -mmin +1440 2>/dev/null)" ]; then
      tmp="$cache/$f.tmp"
      if curl -fsSL -m 20 "$MANIFEST_BASE/$f" -o "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$cache/$f"
      else
        rm -f "$tmp"
      fi
    fi
  done
  if [ -s "$cache/kiwix-categories.json" ] && [ -s "$cache/wikipedia.json" ]; then
    echo "$cache"
  elif [ -f "$bundled/kiwix-categories.json" ]; then
    echo "$bundled"
  else
    die "No collection lists available (offline and NOMAD not installed yet)."
  fi
}

zim_dir() { echo "$STORAGE_PATH/zim"; }

gb() { awk -v mb="$1" 'BEGIN{printf (mb < 10240 ? "%.1f" : "%d"), mb / 1024}'; }

# Print the planned library as TSV: id <tab> size_mb <tab> filename <tab> group
plan_library() {
  local d entry cat tier
  d="$(manifest_dir)" || exit 1
  if [ -n "$WIKIPEDIA" ] && [ "$WIKIPEDIA" != "none" ]; then
    jq -r --arg o "$WIKIPEDIA" '.options[] | select(.id == $o)
      | ["wikipedia-" + .id, .size_mb, (.url | split("/") | last), "wikipedia:" + .id] | @tsv' "$d/wikipedia.json" \
      | grep . || die "Unknown WIKIPEDIA option '$WIKIPEDIA' (see $d/wikipedia.json)"
  fi
  for entry in $LIBRARY; do
    cat="${entry%%:*}"; tier="${entry#*:}"
    jq -r --arg c "$cat" --arg t "$cat-$tier" --arg g "$entry" '
      def res($cat; $slug):
        ($cat.tiers[] | select(.slug == $slug)) as $tier
        | ($tier.resources // []) + (if $tier.includesTier then res($cat; $tier.includesTier) else [] end);
      .categories[] | select(.slug == $c) as $cat
      | res($cat; $t)[] | [.id, .size_mb, (.url | split("/") | last), $g] | @tsv' "$d/kiwix-categories.json" \
      | grep . || die "Unknown library tier '$entry' (format category:tier, e.g. medicine:standard)"
  done | awk -F'\t' '!seen[$1]++'
}

# Is resource present on disk? Matches any version of the same id.
have_resource() {
  local id="$1" file="$2" group="${3:-}"
  # Non-ZIM resources (e.g. the FDA drug database) are fetched by NOMAD itself.
  case "$file" in *.zim) ;; *) [ -f "$NOMAC_STATE/requested-tier-$group" ]; return ;; esac
  [ -f "$(zim_dir)/$file" ] && return 0
  # Any dated edition counts (NOMAD's content updates replace files with newer
  # ones): wikipedia_en_top_mini_2026-06.zim -> wikipedia_en_top_mini_*.zim
  ls "$(zim_dir)/${file%_*}_"*.zim >/dev/null 2>&1 && return 0
  case "$id" in wikipedia-*) return 1 ;; esac
  ls "$(zim_dir)/${id}_"*.zim >/dev/null 2>&1
}

cmd_content() {
  load_config; apply_profile_defaults
  local dry=0 force=0 a plan id mb file group missing_mb=0 total_mb=0 free avail groups=""
  for a in "$@"; do case "$a" in --dry-run) dry=1 ;; --force) force=1 ;; esac; done
  [ -n "$WIKIPEDIA$LIBRARY$APPS" ] || { ok "No content configured (set PROFILE or LIBRARY in nomac.conf)"; return 0; }

  plan="$(plan_library)"
  info "Planned library (PROFILE=${PROFILE:-none})"
  while IFS=$'\t' read -r id mb file group; do
    [ -n "$id" ] || continue
    total_mb=$((total_mb + ${mb%.*}))
    if have_resource "$id" "$file" "$group"; then
      printf '   %s✓%s %-42s %6s MB  %s\n' "$C_GRN" "$C_OFF" "$id" "$mb" "$group"
    else
      missing_mb=$((missing_mb + ${mb%.*}))
      printf '   %s+%s %-42s %6s MB  %s\n' "$C_YEL" "$C_OFF" "$id" "$mb" "$group"
      case " $groups " in *" $group "*) ;; *) groups="$groups $group" ;; esac
    fi
  done <<EOF
$plan
EOF
  free="$(free_gb "$STORAGE_PATH")"; avail=$(( (free - MIN_FREE_GB) * 1024 ))
  echo "   Total $(gb "$total_mb") GB · to download $(gb "$missing_mb") GB · free $free GB (keeping $MIN_FREE_GB GB spare)"
  [ -n "$APPS" ] && echo "   Apps: $APPS"

  if [ "$missing_mb" -gt "$avail" ] && [ "$force" != 1 ]; then
    die "Not enough space for this plan. Use a smaller WIKIPEDIA option or lower tiers, move STORAGE_PATH to the SSD, or re-run with --force."
  fi
  [ "$dry" = 1 ] && return 0
  nomad_ready || die "NOMAD is not running."

  install_apps
  for group in $groups; do
    case "$group" in
      wikipedia:*)
        api_post /api/zim/wikipedia/select "{\"optionId\":\"${group#wikipedia:}\"}" >/dev/null \
          && ok "Wikipedia (${group#wikipedia:}) download started" || warn "Wikipedia request failed"
        ;;
      *)
        if [ "$force" != 1 ] && [ -f "$NOMAC_STATE/requested-tier-$group" ] \
           && [ -z "$(find "$NOMAC_STATE/requested-tier-$group" -mmin +1440 2>/dev/null)" ]; then
          ok "$group already requested today (downloads in progress?)"; continue
        fi
        if api_post /api/zim/download-category-tier "{\"categorySlug\":\"${group%%:*}\",\"tierSlug\":\"${group%%:*}-${group#*:}\"}" >/dev/null; then
          touch "$NOMAC_STATE/requested-tier-$group"
          ok "$group download started"
        else
          warn "$group request failed"
        fi
        ;;
    esac
  done
  echo "   Progress shows in NOMAD. Large downloads can take hours; re-run ./nomac content to see what's still missing."
}

install_apps() {
  local app existing
  existing="$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)"
  # Kiwix first: the library needs it.
  for app in $(echo "$APPS" | tr ' ' '\n' | awk '$0=="nomad_kiwix_server"{print; next} {rest=rest" "$0} END{print rest}'); do
    printf '%s' "$app" | grep -Eq '^nomad_[a-z0-9_]+$' || { warn "Skipping invalid app name: $app"; continue; }
    if echo "$existing" | grep -qx "$app"; then ok "App $app installed"; continue; fi
    if api_post /api/system/services/install "{\"service_name\":\"$app\"}" >/dev/null 2>&1; then
      ok "Installing app $app"
    else
      warn "Could not install $app (name changed upstream? see Supply Depot in NOMAD)"
    fi
  done
}
