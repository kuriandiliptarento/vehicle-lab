#!/usr/bin/env bash
# Prepare staged Keystone/Pilot contexts, then build vehicle-lab-car:local.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${LAB_ENV:-$LAB_DIR/lab.env}"

"$SCRIPT_DIR/prepare-build-contexts.sh"

cd "$LAB_DIR"
if [[ -f "$ENV_FILE" ]]; then
  docker compose --env-file "$ENV_FILE" build car "$@"
else
  docker compose build car "$@"
fi
