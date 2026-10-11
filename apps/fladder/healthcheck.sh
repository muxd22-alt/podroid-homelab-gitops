#!/usr/bin/env bash
# Healthcheck: fladder — probes the health_url declared in app.yml.
set -euo pipefail

DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
APP_YML="$DIR/app.yml"

URL=""
if [ -f "$APP_YML" ]; then
  URL="$(sed -n 's/^health_url:[[:space:]]*//p' "$APP_YML" | head -n 1)"
fi
if [ -z "$URL" ]; then
  echo "healthcheck: no health_url in $APP_YML" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "healthcheck: curl is not installed" >&2
  exit 1
fi

curl -f -sS --max-time 10 "$URL" -o /dev/null || exit 1
echo "OK: $(basename "$DIR") healthy at $URL"
