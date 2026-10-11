#!/bin/sh
# ---------------------------------------------------------------------------
# Podroid GitOps homelab — one-line installer (runs INSIDE the Podroid VM).
#
#   curl -fsSL https://raw.githubusercontent.com/muxd22-alt/podroid-homelab-gitops/main/bootstrap/install.sh | sh
#
# Idempotent: safe to re-run. Upgrades the clone, refreshes missing .env
# files, reinstalls the service/cron entries and redeploys the stack.
# ---------------------------------------------------------------------------
set -eu

REPO_URL="${REPO_URL:-https://github.com/muxd22-alt/podroid-homelab-gitops.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-${HOME:-/root}/homelab}"
LOG_DIR="/tmp/homelab-logs"
INSTALL_LOG="$LOG_DIR/install.log"

log() { printf '[podroid-install] %s\n' "$*"; }
die() { printf '[podroid-install] ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. Must run as root inside the VM -------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  die "run as root inside the Podroid VM (curl ... | sh)"
fi

# --- 1. Guards: Alpine on aarch64 only --------------------------------------
if [ ! -f /etc/alpine-release ]; then
  die "Alpine Linux required — /etc/alpine-release not found (this installer only targets Podroid's VM)"
fi
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) log "Architecture OK: $ARCH" ;;
  *) die "ARM64 (aarch64) required, detected: $ARCH — x86 emulation would be ~10x slower" ;;
esac
log "Alpine $(cat /etc/alpine-release) on $ARCH"

# --- 2. Packages ------------------------------------------------------------
log "Installing packages (podman, podman-compose, openrc, dcron, ...)..."
apk add --no-cache git curl bash podman podman-compose openrc dcron

# --- 3. Clone or update the repository -------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
  log "Existing install at $INSTALL_DIR — updating..."
  git -C "$INSTALL_DIR" fetch origin "$BRANCH"
  if ! git -C "$INSTALL_DIR" merge --ff-only "origin/$BRANCH" >/dev/null 2>&1; then
    # After a rollback the local HEAD trails origin; secrets live in .env
    # (untracked), so adopting origin is safe and keeps the install idempotent.
    log "WARN: local history diverged from origin/$BRANCH — resetting to origin"
    git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH" >/dev/null 2>&1
  fi
else
  log "Cloning $REPO_URL ..."
  git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

# --- 4. Secrets templates -> .env (never overwrite real secrets) ------------
log "Creating missing .env files from .env.example ..."
find "$INSTALL_DIR/apps" -mindepth 2 -maxdepth 2 -name '.env.example' 2>/dev/null |
  while IFS= read -r example; do
    target="$(dirname "$example")/.env"
    if [ ! -f "$target" ]; then
      cp "$example" "$target"
      log "  created ${target#"$INSTALL_DIR"/} — edit it to set real values"
    fi
  done

# --- 5. RAM-disk logging (protects UFS flash from write wear) ---------------
mkdir -p "$LOG_DIR"
chmod 0755 "$LOG_DIR"
log "RAM-disk log directory ready: $LOG_DIR"

# --- 5b. Local domains -> 127.0.0.1 (routing table: muxdN.com -> service) ----
log "Registering local domains in /etc/hosts ..."
for domain in muxd1.com muxd2.com muxd3.com muxd4.com muxd5.com muxd.local; do
  if grep -qE "^[^#]*[[:space:]]$domain([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    continue
  fi
  printf '127.0.0.1 %s\n' "$domain" >> /etc/hosts
  log "  added: 127.0.0.1 $domain"
done

# --- 5c. Podman API socket (watchtower needs it to auto-update images) ------
if [ -f "$INSTALL_DIR/bootstrap/podman-socket" ]; then
  log "Installing OpenRC service 'podman-socket' ..."
  sed "s|^SOCKET_PATH=.*|SOCKET_PATH=\"/run/podman/podman.sock\"|" "$INSTALL_DIR/bootstrap/podman-socket" \
    > /etc/init.d/podman-socket
  chmod 0755 /etc/init.d/podman-socket
  rc-update add podman-socket default 2>/dev/null || log "WARN: could not enable podman-socket"
  if ! rc-service podman-socket status >/dev/null 2>&1; then
    rc-service podman-socket start >/dev/null 2>&1 || log "WARN: could not start podman-socket"
  fi
fi

# --- 6. OpenRC service (one-shot sync at boot) ------------------------------
log "Installing OpenRC service 'podroid-gitops'..."
sed "s|^HOMELAB_DIR=.*|HOMELAB_DIR=\"$INSTALL_DIR\"|" "$INSTALL_DIR/bootstrap/podroid-gitops" \
  > /etc/init.d/podroid-gitops
chmod 0755 /etc/init.d/podroid-gitops
if ! rc-update add podroid-gitops default; then
  log "WARN: could not enable podroid-gitops at boot"
fi

# --- 7. Cron: sync every 12 hours (dcron reads /etc/crontab) ----------------
CRON_FILE="/etc/crontab"
if grep -qF "$INSTALL_DIR/bootstrap/updater.sh" "$CRON_FILE" 2>/dev/null; then
  log "cron entry already installed"
else
  printf '%s\n' "0 */12 * * * root $INSTALL_DIR/bootstrap/updater.sh" >> "$CRON_FILE"
  log "installed cron entry: 0 */12 * * * root $INSTALL_DIR/bootstrap/updater.sh"
fi
rc-update add crond default 2>/dev/null || log "WARN: could not enable crond"
if ! rc-service crond status >/dev/null 2>&1; then
  rc-service crond start >/dev/null 2>&1 || log "WARN: could not start crond"
fi

# --- 8. homelab CLI ---------------------------------------------------------
ln -sf "$INSTALL_DIR/bootstrap/homelab" /usr/local/bin/homelab
log "CLI installed: homelab (sync|status|apps|logs|version)"

# --- 9. First deploy of every app ------------------------------------------
log "Deploying all apps..."
DEPLOY_FAILED=0
for dir in "$INSTALL_DIR"/apps/*/; do
  [ -f "$dir/compose.yml" ] || continue
  name="$(basename "$dir")"
  if (cd "$dir" && podman-compose up -d) >>"$INSTALL_LOG" 2>&1; then
    log "  started: $name"
  else
    log "  WARN: failed to start $name (see $INSTALL_LOG)"
    DEPLOY_FAILED=1
  fi
done

# --- 10. Health checks (with retries) ---------------------------------------
log "Running health checks..."
sleep 5
HEALTH_FAILED=0
for dir in "$INSTALL_DIR"/apps/*/; do
  [ -x "$dir/healthcheck.sh" ] || continue
  name="$(basename "$dir")"
  attempt=1
  healthy=0
  while [ "$attempt" -le 5 ]; do
    if (cd "$dir" && ./healthcheck.sh) >>"$INSTALL_LOG" 2>&1; then
      healthy=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 5
  done
  if [ "$healthy" -eq 1 ]; then
    log "  healthy: $name"
  else
    log "  UNHEALTHY: $name (see $INSTALL_LOG)"
    HEALTH_FAILED=1
  fi
done

# --- 11. Optional Podroid helpers (skip cleanly when absent) ----------------
if command -v podroid-forward >/dev/null 2>&1; then
  log "Registering podroid-forward rules from app.yml ports..."
  find "$INSTALL_DIR/apps" -mindepth 2 -maxdepth 2 -name 'app.yml' 2>/dev/null |
    while IFS= read -r meta; do
      port="$(sed -n 's/^host_port:[[:space:]]*//p' "$meta" | head -n 1)"
      case "$port" in
        ''|*[!0-9]*) continue ;;
      esac
      if [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
        if podroid-forward add "$port" "$port" tcp >/dev/null 2>&1; then
          log "  forwarded: tcp/$port"
        else
          log "  WARN: could not forward tcp/$port (may already exist)"
        fi
      fi
    done
else
  log "podroid-forward not found — skipping port forwarding (OK)"
fi

if command -v podroid-notify >/dev/null 2>&1; then
  podroid-notify "Podroid GitOps" "Homelab installed and deployed" >/dev/null 2>&1 || true
fi

# --- 12. Summary -------------------------------------------------------------
log "DONE."
log "  manual sync : homelab sync"
log "  status      : homelab status"
log "  updater log : $LOG_DIR/updater.log"
if [ "$DEPLOY_FAILED" -ne 0 ] || [ "$HEALTH_FAILED" -ne 0 ]; then
  log "WARN: some apps failed to deploy or go healthy — check $INSTALL_LOG"
  exit 1
fi
exit 0
