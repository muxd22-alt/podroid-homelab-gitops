#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Podroid GitOps self-updater — runs every 12h via cron, or on demand.
#
#   updater.sh                 one sync cycle (fetch, deploy changed, healthcheck, rollback)
#   updater.sh --boot          reconcile: make sure every app is running (used by OpenRC)
#   updater.sh --refresh-images force an image refresh this cycle
#
# Guarantees:
#   * a lock file so two runs never overlap
#   * all logs go to the RAM disk: /tmp/homelab-logs/updater.log
#   * failed healthchecks roll the repo back to the previously deployed commit
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="${REPO_DIR:-${HOME:-/root}/homelab}"
BRANCH="${BRANCH:-main}"
LOG_DIR="${LOG_DIR:-/tmp/homelab-logs}"
LOG_FILE="$LOG_DIR/updater.log"
LOCK_DIR="$LOG_DIR/updater.lock"
STAMP_FILE="$LOG_DIR/last-image-refresh"
HEALTH_RETRIES="${HEALTH_RETRIES:-5}"
HEALTH_WAIT="${HEALTH_WAIT:-10}"
IMAGE_REFRESH_SECS="${IMAGE_REFRESH_SECS:-86400}"

MODE="sync"
case "${1:-}" in
  ""|--sync) MODE="sync" ;;
  --boot) MODE="boot" ;;
  --refresh-images) MODE="sync"; IMAGE_REFRESH_SECS=0 ;;
  -h|--help)
    printf 'usage: %s [--sync|--boot|--refresh-images]\n' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s [--sync|--boot|--refresh-images]\n' "$0" >&2
    exit 2
    ;;
esac

log() { printf '%s [updater] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

notify() {
  if command -v podroid-notify >/dev/null 2>&1; then
    podroid-notify "$1" "$2" >/dev/null 2>&1 || true
  fi
}

# --- Lock file (mkdir is atomic; stale locks are broken) --------------------
cleanup_lock() {
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_lock() {
  mkdir -p "$LOG_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    trap cleanup_lock EXIT
    return 0
  fi
  local oldpid
  oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    log "another updater run is active (pid $oldpid) — exiting"
    exit 0
  fi
  log "stale lock found (pid ${oldpid:-unknown} not running) — breaking it"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  trap cleanup_lock EXIT
}

# --- Helpers ----------------------------------------------------------------
app_dirs() {
  find "$REPO_DIR/apps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

add_unique() {
  local -n _arr="$1"
  local value="$2" item
  for item in "${_arr[@]}"; do
    if [ "$item" = "$value" ]; then
      return 0
    fi
  done
  _arr+=("$value")
}

deploy_app() {
  local name="$1" dir="$REPO_DIR/apps/$1"
  if [ ! -f "$dir/compose.yml" ]; then
    log "WARN: cannot deploy $name — no compose.yml"
    return 1
  fi
  log "Deploying $name ..."
  if (cd "$dir" && podman-compose up -d --remove-orphans) >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  log "WARN: podman-compose up failed for $name"
  return 1
}

remove_app() {
  local name="$1" cid
  log "Cleaning up removed app: $name"
  if podman rm -f "$name" >/dev/null 2>&1; then
    log "  removed container $name"
  fi
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    podman rm -f "$cid" >/dev/null 2>&1 || true
    log "  removed container $cid (project label: $name)"
  done < <(podman ps -a -q --filter "label=com.docker.compose.project=$name" 2>/dev/null || true)
}

healthcheck_app() {
  local name="$1" dir="$REPO_DIR/apps/$1" attempt
  if [ ! -x "$dir/healthcheck.sh" ]; then
    log "HEALTH SKIP: $name (no executable healthcheck.sh)"
    return 0
  fi
  attempt=1
  while [ "$attempt" -le "$HEALTH_RETRIES" ]; do
    if (cd "$dir" && ./healthcheck.sh) >>"$LOG_FILE" 2>&1; then
      log "HEALTH OK  : $name"
      return 0
    fi
    log "HEALTH WAIT: $name (attempt $attempt/$HEALTH_RETRIES)"
    attempt=$((attempt + 1))
    if [ "$attempt" -le "$HEALTH_RETRIES" ]; then
      sleep "$HEALTH_WAIT"
    fi
  done
  log "HEALTH FAIL: $name"
  return 1
}

# Pull image tags; move apps whose digest changed into the deploy list.
refresh_images() {
  local now last dir name image old new
  now="$(date +%s)"
  last="$(cat "$STAMP_FILE" 2>/dev/null || echo 0)"
  if [ "$((now - last))" -lt "$IMAGE_REFRESH_SECS" ]; then
    return 0
  fi
  printf '%s\n' "$now" > "$STAMP_FILE"
  log "Image refresh window reached — pulling current tags"
  while IFS= read -r dir; do
    name="$(basename "$dir")"
    image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$dir/compose.yml" 2>/dev/null | head -n 1 | tr -d "\"'")"
    [ -n "$image" ] || continue
    old="$(podman image inspect --format '{{.Digest}}' "$image" 2>/dev/null || echo none)"
    if ! podman pull "$image" >>"$LOG_FILE" 2>&1; then
      log "WARN: pull failed for $image — keeping current image"
      continue
    fi
    new="$(podman image inspect --format '{{.Digest}}' "$image" 2>/dev/null || echo none)"
    if [ "$old" != "$new" ]; then
      log "Image updated: $image (${old:0:12} -> ${new:0:12})"
      add_unique CHANGED_APPS "$name"
      IMAGE_CHANGED=1
    fi
  done < <(app_dirs)
}

# --- One full cycle ---------------------------------------------------------
cycle() {
  local prev remote line rest name failed=0 dir

  if [ ! -d "$REPO_DIR/.git" ] || [ ! -d "$REPO_DIR/apps" ]; then
    log "ERROR: repository not found at $REPO_DIR"
    return 1
  fi
  cd "$REPO_DIR"

  prev="$(git rev-parse HEAD)"
  log "Cycle start: $prev (mode=$MODE)"

  CHANGED_APPS=()
  DELETED_APPS=()
  GIT_CHANGED=0
  IMAGE_CHANGED=0

  refresh_images

  if ! git fetch origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
    log "WARN: git fetch failed (no network?) — skipping git sync"
  else
    remote="$(git rev-parse "origin/$BRANCH")"
    if [ "$(git rev-list --count "$remote..HEAD")" -gt 0 ]; then
      log "Local HEAD is ahead of origin/$BRANCH (remote rewound) — adopting remote"
      git reset --hard "$remote" >>"$LOG_FILE" 2>&1 || true
    elif [ "$prev" = "$remote" ]; then
      if [ "$IMAGE_CHANGED" -eq 0 ] && [ "$MODE" != "boot" ]; then
        log "No changes on origin/$BRANCH — nothing to do"
        return 0
      fi
    else
      log "Changes detected: ${prev:0:7} -> ${remote:0:7}"
      if git pull --ff-only origin "$BRANCH" >>"$LOG_FILE" 2>&1; then
        GIT_CHANGED=1
        while IFS= read -r line; do
          rest="${line#apps/}"
          case "$rest" in
            */*) ;;
            *) continue ;;
          esac
          name="${rest%%/*}"
          [ -n "$name" ] || continue
          if [ -d "$REPO_DIR/apps/$name" ]; then
            add_unique CHANGED_APPS "$name"
          else
            add_unique DELETED_APPS "$name"
          fi
        done < <(git diff --name-only "$prev"..HEAD -- apps/ 2>/dev/null || true)
        log "Changed apps: ${CHANGED_APPS[*]:-none}"
        log "Removed apps: ${DELETED_APPS[*]:-none}"
      else
        log "WARN: git pull failed — skipping git sync"
      fi
    fi
  fi

  if [ "$MODE" = "boot" ]; then
    log "Boot reconcile: ensuring every app is running"
    CHANGED_APPS=()
    while IFS= read -r dir; do
      add_unique CHANGED_APPS "$(basename "$dir")"
    done < <(app_dirs)
  fi

  for name in "${DELETED_APPS[@]}"; do
    remove_app "$name"
  done

  local deploy_failed=0
  if [ "${#CHANGED_APPS[@]}" -gt 0 ]; then
    for name in "${CHANGED_APPS[@]}"; do
      if ! deploy_app "$name"; then
        deploy_failed=1
      fi
    done
    log "Waiting ${HEALTH_WAIT}s for containers to initialize..."
    sleep "$HEALTH_WAIT"
  fi

  if [ "${#CHANGED_APPS[@]}" -gt 0 ]; then
    for name in "${CHANGED_APPS[@]}"; do
      if ! healthcheck_app "$name"; then
        failed=1
      fi
    done
  fi
  if [ "$deploy_failed" -ne 0 ]; then
    failed=1
    log "One or more deploys failed"
  fi

  if [ "$failed" -ne 0 ]; then
    if [ "$GIT_CHANGED" -eq 1 ]; then
      log "HEALTHCHECK FAILED - ROLLED BACK TO $prev"
      git reset --hard "$prev" >>"$LOG_FILE" 2>&1 || true
      for name in "${CHANGED_APPS[@]}"; do
        if [ -d "$REPO_DIR/apps/$name" ]; then
          deploy_app "$name" || true
        else
          remove_app "$name"
        fi
      done
      log "Rollback redeploy finished at $(git rev-parse --short HEAD)"
      notify "GitOps Rollback" "Healthcheck failed, reverted to ${prev:0:7}"
    else
      log "HEALTHCHECK FAILED - no git changes to roll back (image/runtime issue)"
      notify "GitOps healthcheck failed" "See $LOG_FILE"
    fi
    return 1
  fi

  if [ "$MODE" = "boot" ]; then
    log "Boot reconcile finished — every app deployed and healthy"
    return 0
  fi

  if [ "${#CHANGED_APPS[@]}" -gt 0 ]; then
    log "DEPLOYMENT SUCCESSFUL - COMMIT $(git rev-parse HEAD)"
    podman image prune -f >>"$LOG_FILE" 2>&1 || true
    notify "GitOps sync OK" "Commit $(git rev-parse --short HEAD) healthy"
  else
    log "Already current — nothing to deploy"
  fi
  return 0
}

acquire_lock
cycle
