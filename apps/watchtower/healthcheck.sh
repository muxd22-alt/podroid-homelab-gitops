#!/usr/bin/env bash
# Healthcheck: watchtower has no HTTP API — verify the container is running
# through the podman socket instead.
set -euo pipefail

APP="watchtower"
status="$(podman inspect -f '{{.State.Status}}' "$APP" 2>/dev/null || echo missing)"

if [ "$status" = "running" ]; then
  echo "OK: $APP container is running"
  exit 0
fi

echo "FAIL: $APP container status: $status" >&2
exit 1
