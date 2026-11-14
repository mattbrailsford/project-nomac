# shellcheck shell=bash
# Building the arm64 admin image from upstream source, applying versions,
# rollback and image cleanup.

resolve_version() {
  local v="$1"
  if [ -z "$v" ] || [ "$v" = "latest" ]; then
    v="$(latest_upstream_version)"
    [ -n "$v" ] || die "Could not look up the latest Project NOMAD release (are you online?)."
  fi
  echo "${v#v}"
}

upstream_checkout() {
  local v="$1" tag="v$1"
  if [ ! -d "$NOMAC_UPSTREAM/.git" ]; then
    info "Downloading Project NOMAD $tag source"
    git clone -q --depth 1 --branch "$tag" "$UPSTREAM_URL" "$NOMAC_UPSTREAM"
  else
    info "Fetching Project NOMAD $tag source"
    git -C "$NOMAC_UPSTREAM" fetch -q --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    git -C "$NOMAC_UPSTREAM" -c advice.detachedHead=false checkout -q --force "$tag"
  fi
}

image_exists() { docker image inspect "$IMAGE_REPO:$1" >/dev/null 2>&1; }

build_image() {
  local v="$1"
  if image_exists "$v" && [ "${NOMAC_REBUILD:-0}" != "1" ]; then
    ok "Image $IMAGE_REPO:$v already built"
    return 0
  fi
  upstream_checkout "$v"
  info "Building $IMAGE_REPO:$v for Apple Silicon (first build takes 5–15 minutes)"
  docker build --platform linux/arm64 \
    --build-arg VERSION="$v" \
    --build-arg BUILD_DATE="$(now_iso)" \
    --build-arg VCS_REF="$(git -C "$NOMAC_UPSTREAM" rev-parse --short HEAD)" \
    -t "$IMAGE_REPO:$v" "$NOMAC_UPSTREAM"
  ok "Built $IMAGE_REPO:$v"
}

current_version() { env_get NOMAD_VERSION; }

# Point the stack at version $1 and (re)start it, remembering the old version.
apply_version() {
  local v="$1" cur
  cur="$(current_version)"
  if [ -n "$cur" ] && [ "$cur" != "$v" ]; then
    echo "$cur" > "$NOMAC_STATE/previous_version"
  fi
  env_set NOMAD_VERSION "$v"
  compose up -d --remove-orphans
}

# Remove nomac admin images other than the current and previous versions.
prune_images() {
  local cur prev tag
  cur="$(current_version)"
  prev="$(cat "$NOMAC_STATE/previous_version" 2>/dev/null || true)"
  docker images --format '{{.Tag}}' "$IMAGE_REPO" | while read -r tag; do
    [ -z "$tag" ] || [ "$tag" = "$cur" ] || [ "$tag" = "$prev" ] && continue
    info "Removing old image $IMAGE_REPO:$tag"
    docker rmi "$IMAGE_REPO:$tag" >/dev/null 2>&1 || warn "Could not remove $IMAGE_REPO:$tag (in use?)"
  done
  # Dangling layers and build cache left by rebuilds.
  docker image prune -f >/dev/null 2>&1 || true
  docker builder prune -f >/dev/null 2>&1 || true
}

cmd_rollback() {
  local prev cur
  prev="$(cat "$NOMAC_STATE/previous_version" 2>/dev/null || true)"
  cur="$(current_version)"
  [ -n "$prev" ] || die "No previous version recorded."
  image_exists "$prev" || die "Image for $prev is gone; run: nomac update $prev"
  info "Rolling back NOMAD $cur -> $prev"
  apply_version "$prev"
  ok "Now running $prev. Note: database migrations from $cur are not undone."
}
