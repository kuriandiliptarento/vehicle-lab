#!/usr/bin/env bash
# macOS / Docker Desktop: create a plain Docker bridge as labnet (no sudo, no labbus).
# Linux hosts should keep using scripts/host-net.sh (macvlan).
#
#   ./scripts/mac-net.sh
#   ./scripts/mac-net.sh teardown
#
# Compatible with macOS bash 3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${LAB_ENV:-$LAB_DIR/lab.env}"

TEARDOWN=0

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/mac-net.sh [teardown]

  (default)  create Docker bridge network labnet if missing; verify if present
  teardown   remove labnet (warns if containers are still attached)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    teardown) TEARDOWN=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

LABNET_NAME="${LABNET_NAME:-labnet}"
LAB_SUBNET="${LAB_SUBNET:-10.74.0.0/24}"
LAB_SIM_IP="${LAB_SIM_IP:-10.74.0.2}"
LAB_SIM_CONSOLE_PORT="${LAB_SIM_CONSOLE_PORT:-18090}"

die() { echo "mac-net: $*" >&2; exit 1; }

if ! command -v docker >/dev/null 2>&1; then
  die "docker not found on PATH"
fi
if ! docker info >/dev/null 2>&1; then
  die "docker is not running (start Docker Desktop and retry)"
fi

network_exists() {
  docker network inspect "$LABNET_NAME" >/dev/null 2>&1
}

verify_existing() {
  local driver subnet
  driver="$(docker network inspect "$LABNET_NAME" --format '{{.Driver}}')"
  subnet="$(docker network inspect "$LABNET_NAME" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  if [ "$driver" != "bridge" ]; then
    die "$LABNET_NAME exists but driver is '$driver' (want bridge). Remove the stale network (e.g. leftover macvlan from Linux host-net) then re-run: docker network rm $LABNET_NAME"
  fi
  if [ "$subnet" != "$LAB_SUBNET" ]; then
    die "$LABNET_NAME exists but subnet is '$subnet' (want $LAB_SUBNET). Remove it and re-run, or fix LAB_SUBNET in lab.env"
  fi
  echo "mac-net: $LABNET_NAME already exists (bridge, $subnet)"
}

teardown_net() {
  if ! network_exists; then
    echo "mac-net: $LABNET_NAME not present"
    return 0
  fi
  # Containers still attached → docker network rm fails; surface a clear warning.
  attached="$(docker network inspect "$LABNET_NAME" --format '{{len .Containers}}')"
  if [ "${attached:-0}" != "0" ]; then
    echo "mac-net: warning: $attached container(s) still attached to $LABNET_NAME — stop/rm them first" >&2
    docker network inspect "$LABNET_NAME" --format '{{range .Containers}}  {{.Name}}{{"\n"}}{{end}}' >&2 || true
  fi
  echo "mac-net: removing docker network $LABNET_NAME"
  docker network rm "$LABNET_NAME"
  echo "mac-net: teardown done"
}

if [ "$TEARDOWN" -eq 1 ]; then
  teardown_net
  exit 0
fi

# Do not pass --gateway: Docker assigns 10.74.0.1 on this subnet by default.
# LAB_GATEWAY in lab.env is for MQTT socat / Autrio (host.docker.internal), not this create.
if network_exists; then
  verify_existing
else
  echo "mac-net: creating docker bridge $LABNET_NAME (subnet=$LAB_SUBNET)"
  docker network create \
    -d bridge \
    --subnet "$LAB_SUBNET" \
    "$LABNET_NAME"
  verify_existing
fi

echo ""
echo "ready (macOS / Docker Desktop):"
echo "  docker network=$LABNET_NAME (bridge, $LAB_SUBNET)"
echo "  simulator IP: $LAB_SIM_IP"
echo "  next:"
echo "    1) Phase 1 multicast test (same throwaway containers as README)"
echo "    2) docker compose --env-file lab.env build simulator"
echo "    3) ./scripts/build-car.sh"
echo "    4) docker compose -f docker-compose.yml -f docker-compose.mac.yml --env-file lab.env up -d simulator"
echo "    5) console: http://localhost:${LAB_SIM_CONSOLE_PORT}/"
echo "    6) ./scripts/up-car.sh --vin <VIN> --apps <family>"
