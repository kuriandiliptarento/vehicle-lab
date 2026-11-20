#!/usr/bin/env bash
# One-off car container: VIN, apps, and per-tenant Keystone identity from the CLI.
#
#   ./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV
#   ./scripts/up-car.sh --vin … --apps gai_EV \
#       --tenant-key other-org --birth-secret <hex> --autrio-url http://10.74.0.1:8002
#
# lab.env supplies defaults (LAB_* + optional KEYSTONE_*). CLI flags override tenant fields.
# Rebuild the car image once before first use: ./scripts/build-car.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${LAB_ENV:-$LAB_DIR/lab.env}"
IMAGE="${CAR_IMAGE:-vehicle-lab-car:local}"
LABNET_NAME="${LABNET_NAME:-labnet}"

VIN=""
APPS=""
IP=""
NAME=""
CLI_TENANT_KEY=""
CLI_BIRTH_SECRET=""
CLI_AUTRIO_URL=""
CLI_KEYSTORE_BACKEND=""

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/up-car.sh --vin <17-char-VIN> --apps <family> [options]

  --vin              vehicle identity (required); also KEYSTONE_VIN inside the container
  --apps             gai_EV | gai_ICE | prod_EV | prod_ICE (required)
  --tenant-key       KEYSTONE_TENANT_KEY (overrides lab.env)
  --birth-secret     KEYSTONE_BIRTH_SECRET (overrides lab.env)
  --autrio-url       KEYSTONE_AUTRIO_URL (overrides lab.env)
  --keystore         KEYSTONE_KEYSTORE_BACKEND (default: lab.env or file)
  --ip               static address on labnet (default: next free in 10.74.0.32-63)
  --name             docker container name (default: vehicle-lab-car-<VIN>)

Tenant fields may come from lab.env defaults or from these flags (flags win).
Each tenant/device needs its own birth secret — do not reuse one secret across tenants.

Examples:
  ./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV
  ./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV \
      --tenant-key sample-org --birth-secret "$SECRET"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --vin) VIN="${2:-}"; shift 2 ;;
    --apps|--dbc|--dbc-family) APPS="${2:-}"; shift 2 ;;
    --tenant-key|--tenant) CLI_TENANT_KEY="${2:-}"; shift 2 ;;
    --birth-secret|--secret) CLI_BIRTH_SECRET="${2:-}"; shift 2 ;;
    --autrio-url) CLI_AUTRIO_URL="${2:-}"; shift 2 ;;
    --keystore|--keystore-backend) CLI_KEYSTORE_BACKEND="${2:-}"; shift 2 ;;
    --ip) IP="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$VIN" || -z "$APPS" ]]; then
  usage
  exit 2
fi

if [[ "${#VIN}" -ne 17 ]]; then
  echo "VIN must be 17 characters (got ${#VIN}: $VIN)" >&2
  exit 2
fi

case "$APPS" in
  gai_EV|gai_ICE|prod_EV|prod_ICE) ;;
  gaiev|gai-ev) APPS=gai_EV ;;
  gaiice|gai-ice) APPS=gai_ICE ;;
  prodev|prod-ev) APPS=prod_EV ;;
  prodice|prod-ice) APPS=prod_ICE ;;
  *)
    echo "unknown --apps $APPS (want gai_EV|gai_ICE|prod_EV|prod_ICE)" >&2
    exit 2
    ;;
esac

if [[ ! -f "$ENV_FILE" ]]; then
  echo "missing $ENV_FILE — cp lab.env.example lab.env (LAB_* + optional KEYSTONE_* defaults)" >&2
  exit 2
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

LABNET_NAME="${LABNET_NAME:-labnet}"

# CLI overrides lab.env for per-tenant Keystone identity.
[[ -n "$CLI_TENANT_KEY" ]] && KEYSTONE_TENANT_KEY="$CLI_TENANT_KEY"
[[ -n "$CLI_BIRTH_SECRET" ]] && KEYSTONE_BIRTH_SECRET="$CLI_BIRTH_SECRET"
[[ -n "$CLI_AUTRIO_URL" ]] && KEYSTONE_AUTRIO_URL="$CLI_AUTRIO_URL"
[[ -n "$CLI_KEYSTORE_BACKEND" ]] && KEYSTONE_KEYSTORE_BACKEND="$CLI_KEYSTORE_BACKEND"

: "${KEYSTONE_AUTRIO_URL:?KEYSTONE_AUTRIO_URL missing — set in lab.env or pass --autrio-url}"
: "${KEYSTONE_TENANT_KEY:?KEYSTONE_TENANT_KEY missing — set in lab.env or pass --tenant-key}"
: "${KEYSTONE_BIRTH_SECRET:?KEYSTONE_BIRTH_SECRET missing — set in lab.env or pass --birth-secret}"

if [[ "$KEYSTONE_BIRTH_SECRET" == "CHANGE_ME_BIRTH_SECRET" ]]; then
  echo "set a real KEYSTONE_BIRTH_SECRET in $ENV_FILE or pass --birth-secret" >&2
  exit 2
fi

NAME="${NAME:-vehicle-lab-car-${VIN}}"
# Docker volume names: alphanumeric + underscore/dash
VOL_PREFIX="vehicle-lab-car-${VIN}"

pick_ip() {
  local candidate used
  for candidate in $(seq 32 63); do
    used=0
    if docker network inspect "$LABNET_NAME" --format '{{range .Containers}}{{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null \
      | grep -q "10.74.0.${candidate}/"; then
      used=1
    fi
    if [[ "$used" -eq 0 ]]; then
      echo "10.74.0.${candidate}"
      return 0
    fi
  done
  echo "no free IP in 10.74.0.32-63 on $LABNET_NAME" >&2
  return 1
}

if [[ -z "$IP" ]]; then
  IP="$(pick_ip)"
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image $IMAGE not found — build first:" >&2
  echo "  cd $LAB_DIR && ./scripts/build-car.sh" >&2
  exit 2
fi

if ! docker network inspect "$LABNET_NAME" >/dev/null 2>&1; then
  echo "docker network $LABNET_NAME missing — run: sudo ./scripts/host-net.sh" >&2
  exit 2
fi

if docker inspect "$NAME" >/dev/null 2>&1; then
  echo "container $NAME already exists — stop/rm it or pass --name" >&2
  exit 2
fi

echo "starting $NAME"
echo "  vin=$VIN apps=$APPS ip=$IP network=$LABNET_NAME"
echo "  tenant=$KEYSTONE_TENANT_KEY autrio=$KEYSTONE_AUTRIO_URL"
echo "  bus: $(python3 "$SCRIPT_DIR/bus-id.py" "$VIN" | cut -f2-)"

docker run -d \
  --name "$NAME" \
  --restart unless-stopped \
  --init \
  --network "$LABNET_NAME" \
  --ip "$IP" \
  -e "CAR_VIN=$VIN" \
  -e "DBC_FAMILY=$APPS" \
  -e "LAB_GATEWAY=${LAB_GATEWAY:-10.74.0.1}" \
  -e "LAB_MQTT_BROKER_PORT=${LAB_MQTT_BROKER_PORT:-1883}" \
  -e "KEYSTONE_AUTRIO_URL=$KEYSTONE_AUTRIO_URL" \
  -e "KEYSTONE_TENANT_KEY=$KEYSTONE_TENANT_KEY" \
  -e "KEYSTONE_BIRTH_SECRET=$KEYSTONE_BIRTH_SECRET" \
  -e "KEYSTONE_KEYSTORE_BACKEND=${KEYSTONE_KEYSTORE_BACKEND:-file}" \
  -e "KEYSTONE_PILOT_RUNTIME=${KEYSTONE_PILOT_RUNTIME:-stub}" \
  -e "KEYSTONE_IPC_PATH=/tmp/keystone.sock" \
  -e "KEYSTONE_BIN=/usr/local/bin/keystone" \
  -v "${VOL_PREFIX}-keystone:/var/lib/keystone" \
  -v "${VOL_PREFIX}-pilot:/var/lib/pilot" \
  -v "${VOL_PREFIX}-apps:/var/lib/car" \
  "$IMAGE"

echo "up: $NAME"
echo "  logs: docker logs -f $NAME"
echo "  stop: docker stop $NAME && docker rm $NAME"
echo "  add the same VIN in the simulator console (http://${LAB_SIM_IP:-10.74.0.2}:8090/) with the matching DBC"
