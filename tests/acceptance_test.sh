#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Acceptance tests for podroid-homelab-gitops.
#
# Runs anywhere (bash + python3/yaml minimum). Optional tools:
#   * shellcheck              — required when SHELLCHECK_REQUIRED=1 (CI)
#   * skopeo | docker         — required when REQUIRE_ARM64_MANIFEST=1 (CI)
#   * podman-compose|docker compose — preferred compose parser, python fallback
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 1

FAILS=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*"; }
skip() { printf 'SKIP: %s\n' "$*"; }

PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys' >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done

# --- 1. Required layout ------------------------------------------------------
required_files=(
  ".github/ISSUE_TEMPLATE/new-app.yml"
  ".github/workflows/ai-app-generator.yml"
  ".github/workflows/validate.yml"
  "bootstrap/install.sh"
  "bootstrap/updater.sh"
  "bootstrap/homelab"
  "bootstrap/podroid-gitops"
  "bootstrap/podman-socket"
  "tests/acceptance_test.sh"
  "README.md"
  ".gitignore"
)
for f in "${required_files[@]}"; do
  if [ -f "$f" ]; then pass "exists: $f"; else fail "missing required file: $f"; fi
done

shopt -s nullglob
APP_DIRS=(apps/*/)
if [ "${#APP_DIRS[@]}" -eq 0 ]; then
  fail "no apps found under apps/"
fi

# --- 2. Shell syntax + shellcheck -------------------------------------------
all_scripts=(bootstrap/*.sh bootstrap/homelab bootstrap/podroid-gitops bootstrap/podman-socket apps/*/healthcheck.sh tests/acceptance_test.sh)
for script in "${all_scripts[@]}"; do
  [ -f "$script" ] || continue
  if head -n 1 "$script" | grep -q '/bin/sh'; then
    if sh -n "$script" 2>/tmp/hc-err; then pass "sh -n: $script"; else fail "sh -n: $script — $(cat /tmp/hc-err)"; fi
  else
    if bash -n "$script" 2>/tmp/hc-err; then pass "bash -n: $script"; else fail "bash -n: $script — $(cat /tmp/hc-err)"; fi
  fi
  if [ -x "$script" ]; then pass "executable: $script"; else fail "not executable: $script"; fi
done

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "${all_scripts[@]}"; then
    pass "shellcheck clean (${#all_scripts[@]} scripts)"
  else
    fail "shellcheck reported issues"
  fi
elif [ "${SHELLCHECK_REQUIRED:-0}" = "1" ]; then
  fail "shellcheck is required (SHELLCHECK_REQUIRED=1) but not installed"
else
  skip "shellcheck not installed (set SHELLCHECK_REQUIRED=1 to require it)"
fi

# --- 3. Per-app checks -------------------------------------------------------
declare -A PORT_OWNERS

compose_parser() {
  local dir="$1" out
  if command -v podman-compose >/dev/null 2>&1; then
    out="$( (cd "$dir" && podman-compose config 2>&1) )" && { printf '%s' "$out"; return 0; }
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    out="$( (cd "$dir" && docker compose config 2>&1) )" && { printf '%s' "$out"; return 0; }
  fi
  return 1
}

for dir in "${APP_DIRS[@]}"; do
  dir="${dir%/}"
  app="$(basename "$dir")"
  compose="$dir/compose.yml"
  meta="$dir/app.yml"
  hc="$dir/healthcheck.sh"

  [ -f "$compose" ] || { fail "$app: missing compose.yml"; continue; }
  [ -f "$meta" ] || { fail "$app: missing app.yml"; continue; }

  # 3a. compose parses
  if compose_parser "$dir" >/dev/null; then
    pass "$app: compose config parses (podman-compose/docker compose)"
  elif [ -n "$PYTHON" ] && "$PYTHON" -c 'import yaml' 2>/dev/null; then
    if "$PYTHON" - "$compose" <<'PY'
import sys, yaml
yaml.safe_load(open(sys.argv[1]))
PY
    then
      pass "$app: compose parses with python yaml (no compose tool locally)"
    else
      fail "$app: compose.yml is not valid YAML"
    fi
  else
    fail "$app: no tool available to parse compose.yml"
  fi

  # 3b. arm64 pin
  if grep -Eq '^[[:space:]]*platform:[[:space:]]*linux/arm64[[:space:]]*$' "$compose"; then
    pass "$app: platform pinned to linux/arm64"
  else
    fail "$app: compose.yml must pin platform: linux/arm64"
  fi

  # 3c. image present
  image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$compose" | head -n 1 | tr -d "\"'")"
  if [ -n "$image" ]; then pass "$app: image = $image"; else fail "$app: no image in compose.yml"; fi

  # 3d. host port >= 1024, unique, matches app.yml (optional for background services)
  host_port="$(sed -n 's/^host_port:[[:space:]]*//p' "$meta" | head -n 1 | tr -d "\"'")"
  compose_port="$(sed -n 's/^[[:space:]]*-[[:space:]]*"\{0,1\}\([0-9]\+\):[0-9]\+"\{0,1\}[[:space:]]*$/\1/p' "$compose" | head -n 1)"
  if [ -z "$host_port" ]; then
    if [ -n "$compose_port" ]; then
      fail "$app: no host_port in app.yml but compose publishes port $compose_port"
    else
      pass "$app: background service (no host port)"
    fi
  elif [[ "$host_port" =~ ^[0-9]+$ ]]; then
    if [ "$host_port" -ge 1024 ] && [ "$host_port" -le 65535 ]; then
      pass "$app: host_port $host_port >= 1024"
    else
      fail "$app: host_port $host_port must be in 1024-65535"
    fi
    if [ -n "${PORT_OWNERS[$host_port]:-}" ]; then
      fail "$app: host_port $host_port already used by ${PORT_OWNERS[$host_port]}"
    else
      PORT_OWNERS[$host_port]="$app"
      pass "$app: host_port $host_port unique"
    fi
    if [ -n "$compose_port" ] && [ "$compose_port" != "$host_port" ]; then
      fail "$app: compose publishes port $compose_port but app.yml says $host_port"
    else
      pass "$app: compose port matches app.yml ($host_port)"
    fi
  else
    fail "$app: invalid host_port in app.yml: '$host_port'"
  fi

  # 3e. resource caps
  cpus="$(sed -n 's/^[[:space:]]*cpus:[[:space:]]*//p' "$compose" | head -n 1 | tr -d "\"'")"
  mem="$(sed -n 's/^[[:space:]]*mem_limit:[[:space:]]*//p' "$compose" | head -n 1 | tr -d "\"'")"
  meta_cpus="$(sed -n 's/^cpus:[[:space:]]*//p' "$meta" | head -n 1 | tr -d "\"'")"
  meta_mem="$(sed -n 's/^mem_limit:[[:space:]]*//p' "$meta" | head -n 1 | tr -d "\"'")"
  if [ -n "$cpus" ] && [ -n "$mem" ]; then
    pass "$app: limits cpus=$cpus mem_limit=$mem"
    if [ -z "$PYTHON" ]; then
      skip "$app: resource caps not numerically verified (no python)"
    elif "$PYTHON" - "$cpus" "$mem" <<'PY' >/dev/null 2>&1
import sys
cpus = float(sys.argv[1])
mem = sys.argv[2].lower()
assert cpus <= 2.0, f"cpus {cpus} > 2.0"
n = int(''.join(c for c in mem if c.isdigit()) or 0)
unit = ''.join(c for c in mem if c.isalpha()) or 'm'
mult = {'k': 1024, 'm': 1024**2, 'g': 1024**3}[unit]
assert n * mult <= 1024**3, f"mem_limit {mem} > 1g"
PY
    then
      pass "$app: cpus <= 2.0 and mem_limit <= 1g"
    else
      fail "$app: resource caps exceeded (cpus=$cpus mem=$mem)"
    fi
    if [ "$cpus" = "$meta_cpus" ]; then pass "$app: cpus matches app.yml"; else fail "$app: cpus ($cpus) != app.yml ($meta_cpus)"; fi
    if [ "$mem" = "$meta_mem" ]; then pass "$app: mem_limit matches app.yml"; else fail "$app: mem_limit ($mem) != app.yml ($meta_mem)"; fi
  else
    fail "$app: compose.yml must set cpus and mem_limit"
  fi

  # 3f. logging caps
  if grep -q 'k8s-file' "$compose" && grep -q 'max-size:[[:space:]]*"5m"' "$compose" && grep -q 'max-file:[[:space:]]*"2"' "$compose"; then
    pass "$app: logging k8s-file 5m/2"
  else
    fail "$app: compose.yml must set logging driver k8s-file with max-size 5m and max-file 2"
  fi

  # 3g. restart policy
  if grep -Eq '^[[:space:]]*restart:[[:space:]]*unless-stopped[[:space:]]*$' "$compose"; then
    pass "$app: restart unless-stopped"
  else
    fail "$app: restart policy must be unless-stopped"
  fi

  # 3h. container_name / project name consistency
  cname="$(sed -n 's/^[[:space:]]*container_name:[[:space:]]*//p' "$compose" | head -n 1 | tr -d "\"'")"
  meta_name="$(sed -n 's/^name:[[:space:]]*//p' "$meta" | head -n 1 | tr -d "\"'")"
  if [ "$cname" = "$app" ] && [ "$meta_name" = "$app" ]; then
    pass "$app: name/container_name consistent with directory"
  else
    fail "$app: name (app.yml=$meta_name, container_name=$cname) must equal directory ($app)"
  fi
  if [ -n "$image" ]; then
    meta_image="$(sed -n 's/^image:[[:space:]]*//p' "$meta" | head -n 1 | tr -d "\"'")"
    if [ "$meta_image" = "$image" ]; then pass "$app: image matches app.yml"; else fail "$app: image ($image) != app.yml ($meta_image)"; fi
  fi

  # 3i. healthcheck (HTTP apps probe health_url; background apps inspect the container)
  if [ -f "$hc" ] && [ -x "$hc" ]; then
    pass "$app: healthcheck.sh present and executable"
    health_url="$(sed -n 's/^health_url:[[:space:]]*//p' "$meta" | head -n 1)"
    if grep -q 'health_url' "$hc"; then
      pass "$app: healthcheck reads health_url"
      if [ -n "$health_url" ]; then pass "$app: health_url = $health_url"; else fail "$app: missing health_url in app.yml"; fi
    elif grep -q 'podman inspect' "$hc"; then
      pass "$app: background-service healthcheck (podman inspect)"
    else
      fail "$app: healthcheck.sh must probe health_url or use 'podman inspect'"
    fi
  else
    fail "$app: healthcheck.sh missing or not executable"
  fi

  # 3j. env hygiene: .env.example exists, no .env tracked
  if [ -f "$dir/.env.example" ]; then
    pass "$app: .env.example present"
  else
    fail "$app: missing .env.example"
  fi
done

# --- 3b. Routing table: domains unique + dashboard lists every app -----------
declare -A DOMAIN_OWNERS
for dir in "${APP_DIRS[@]}"; do
  dir="${dir%/}"
  app="$(basename "$dir")"
  domain="$(sed -n 's/^domain:[[:space:]]*//p' "$dir/app.yml" 2>/dev/null | head -n 1 | tr -d "\"'")"
  [ -n "$domain" ] || continue
  if [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    pass "$app: domain format ok ($domain)"
  else
    fail "$app: invalid domain '$domain'"
  fi
  if [ -n "${DOMAIN_OWNERS[$domain]:-}" ]; then
    fail "$app: domain $domain already used by ${DOMAIN_OWNERS[$domain]}"
  else
    DOMAIN_OWNERS[$domain]="$app"
    pass "$app: domain $domain unique"
  fi
done

DASHBOARD_HTML="apps/dashboard/index.html"
if [ -f "$DASHBOARD_HTML" ]; then
  for dir in "${APP_DIRS[@]}"; do
    dir="${dir%/}"
    app="$(basename "$dir")"
    if grep -q "id=\"$app\"" "$DASHBOARD_HTML"; then
      pass "dashboard lists: $app"
    else
      fail "dashboard index.html is missing an entry for $app"
    fi
  done
else
  fail "missing $DASHBOARD_HTML"
fi

# --- 4. No secrets committed --------------------------------------------------
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked_env="$(git ls-files | grep -E '(^|/)\.env$' || true)"
  if [ -z "$tracked_env" ]; then
    pass "no .env files tracked by git"
  else
    fail ".env files tracked by git: $tracked_env"
  fi
else
  if find . -path ./.git -prune -o -name '.env' -type f -print | grep -q .; then
    fail "unignored .env file present on disk (should be gitignored and absent from a fresh clone)"
  else
    pass "no .env files present"
  fi
fi

if grep -q '^\.env$' .gitignore && grep -q 'apps/\*/\.env' .gitignore; then
  pass ".gitignore covers .env"
else
  fail ".gitignore must ignore .env and apps/*/.env"
fi

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  scan_list="$(git ls-files)"
else
  scan_list="$(find . -path ./.git -prune -o -type f -print | sed 's|^\./||')"
fi
secret_hits="$(printf '%s\n' "$scan_list" | grep -vE '\.env\.example$' | xargs -r grep -En '(API_KEY|SECRET|TOKEN|PASSWORD)[[:space:]]*=[[:space:]]*[^[:space:]$#\"'\'']+' 2>/dev/null | grep -v 'changeme' | grep -v 'your-' | grep -v 'placeholder' || true)"
if [ -z "$secret_hits" ]; then
  pass "no secret-looking assignments in tracked files"
else
  fail "possible committed secrets:"$'\n'"$secret_hits"
fi

# --- 5. Updater requirements ---------------------------------------------------
if grep -q '/tmp/homelab-logs/updater.log' bootstrap/updater.sh; then
  pass "updater logs to /tmp/homelab-logs/updater.log"
else
  fail "updater.sh must log to /tmp/homelab-logs/updater.log"
fi
for token in 'ROLLED BACK TO' 'rev-parse HEAD' 'updater.lock' 'image prune -f' '--remove-orphans'; do
  if grep -qF -- "$token" bootstrap/updater.sh; then pass "updater handles: $token"; else fail "updater.sh missing: $token"; fi
done
if grep -Eq '0 \*/12 \* \* \*' bootstrap/install.sh; then
  pass "install.sh installs 12-hour cron entry"
else
  fail "install.sh must install a 0 */12 * * * cron entry"
fi
if grep -qF 'curl -fsSL' README.md && grep -qF 'bootstrap/install.sh | sh' README.md; then
  pass "README documents the one-line installer"
else
  fail "README.md must document the curl ... | sh installer one-liner"
fi

# --- 6. ARM64 manifest verification ---------------------------------------------
check_manifest() {
  local image="$1" raw=""
  if command -v skopeo >/dev/null 2>&1; then
    raw="$(skopeo inspect --raw "docker://$image" 2>/dev/null || true)"
  elif command -v docker >/dev/null 2>&1; then
    raw="$(docker manifest inspect "$image" 2>/dev/null || true)"
  else
    return 2
  fi
  [ -n "$raw" ] || return 2
  echo "$raw" | grep -q 'arm64' && return 0
  return 1
}

for dir in "${APP_DIRS[@]}"; do
  dir="${dir%/}"
  app="$(basename "$dir")"
  image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$dir/compose.yml" | head -n 1 | tr -d "\"'")"
  [ -n "$image" ] || continue
  check_manifest "$image"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$app: $image ships an arm64 manifest"
  elif [ "$rc" -eq 1 ]; then
    fail "$app: $image has NO arm64 manifest — x86 images are forbidden"
  else
    if [ "${REQUIRE_ARM64_MANIFEST:-0}" = "1" ]; then
      fail "$app: cannot verify arm64 manifest for $image (skopeo/docker required)"
    else
      skip "$app: arm64 manifest not verified (no skopeo/docker)"
    fi
  fi
done

# --- 7. Workflow sanity ---------------------------------------------------------
if [ -z "$PYTHON" ]; then
  fail "python is required to validate workflow YAML"
elif "$PYTHON" - <<'PY'
import pathlib, yaml
for wf in pathlib.Path('.github/workflows').glob('*.yml'):
    yaml.safe_load(wf.read_text())
    print(f"PASS: workflow parses: {wf}")
try:
    yaml.safe_load(pathlib.Path('.github/ISSUE_TEMPLATE/new-app.yml').read_text())
    print("PASS: issue template parses")
except Exception as e:
    print(f"FAIL: issue template: {e}")
    raise SystemExit(1)
PY
then
  true
else
  fail "workflow YAML failed to parse"
fi

ai_wf=".github/workflows/ai-app-generator.yml"
if grep -Eq 'issues:' "$ai_wf" && grep -q 'OPENROUTER_API_KEY' "$ai_wf" && grep -q 'pull-requests: write' "$ai_wf"; then
  pass "ai-app-generator wired to issues + OPENROUTER_API_KEY + PR creation"
else
  fail "ai-app-generator workflow incomplete (issues trigger, secret, PR permissions)"
fi
if grep -q ':free' "$ai_wf" && grep -q 'ALLOWED=' "$ai_wf"; then
  pass "ai-app-generator restricts to free models via allowlist"
else
  fail "ai-app-generator must pin/free-list OpenRouter models"
fi

# --- Summary --------------------------------------------------------------------
echo
echo "=============================================="
echo "checks run: $CHECKS   failures: $FAILS"
echo "=============================================="
if [ "$FAILS" -gt 0 ]; then
  exit 1
fi
echo "ALL ACCEPTANCE TESTS PASSED"
exit 0
