#!/usr/bin/env bash
# macOS / Docker Desktop: create a plain Docker bridge as labnet (no sudo, no labbus).
# Mirrors scripts/host-net.sh intent (subnet check, IGMP snooping off) for Docker Desktop.
# Linux hosts should keep using scripts/host-net.sh (macvlan).
#
#   ./scripts/mac-net.sh
#   ./scripts/mac-net.sh teardown
#
# Compatible with macOS bash 3.2 (no process substitution, no associative arrays).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${LAB_ENV:-$LAB_DIR/lab.env}"

TEARDOWN=0

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/mac-net.sh [teardown]

  (default)  require lab.env; create/verify Docker bridge labnet; disable IGMP snooping
  teardown   remove labnet (fails if containers are still attached)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    teardown) TEARDOWN=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

die() { echo "mac-net: $*" >&2; exit 1; }

if [ ! -f "$ENV_FILE" ]; then
  echo "missing $ENV_FILE — cp lab.env.mac.example lab.env" >&2
  exit 2
fi

# shellcheck disable=SC1090
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

LABNET_NAME="${LABNET_NAME:-labnet}"
LAB_SUBNET="${LAB_SUBNET:-10.74.0.0/24}"
# Docker bridge gateway only — not LAB_GATEWAY (that is host.docker.internal for socat/Autrio).
LAB_BRIDGE_GATEWAY="${LAB_BRIDGE_GATEWAY:-10.74.0.1}"
LAB_SIM_IP="${LAB_SIM_IP:-10.74.0.2}"
LAB_SIM_CONSOLE_PORT="${LAB_SIM_CONSOLE_PORT:-18090}"
LAB_NET_HELPER_IMAGE="${LAB_NET_HELPER_IMAGE:-alpine:3.20}"

if ! command -v docker >/dev/null 2>&1; then
  die "docker not found on PATH"
fi
if ! docker info >/dev/null 2>&1; then
  die "docker is not running (start Docker Desktop and retry)"
fi
if ! command -v python3 >/dev/null 2>&1; then
  die "python3 is required for subnet overlap checks"
fi

network_exists() {
  docker network inspect "$LABNET_NAME" >/dev/null 2>&1
}

# Return 0 if want overlaps cidr (same semantics as host-net.sh subnet_overlaps helper).
_cidrs_overlap() {
  local want="$1"
  local cidr="$2"
  python3 - "$want" "$cidr" <<'PY'
import ipaddress, sys
want = ipaddress.ip_network(sys.argv[1], strict=False)
have = ipaddress.ip_network(sys.argv[2], strict=False)
sys.exit(0 if want.overlaps(have) else 1)
PY
}

# Collect candidate CIDRs into a temp file (bash 3.2 — no process substitution).
# Docker network IPAM subnets (skip labnet) + Mac host IPv4s as /32.
_collect_overlap_cidrs() {
  local out="$1"
  local nid name subnet s ip
  : >"$out"
  for nid in $(docker network ls -q); do
    [ -n "$nid" ] || continue
    name="$(docker network inspect "$nid" --format '{{.Name}}')"
    if [ "$name" = "$LABNET_NAME" ]; then
      continue
    fi
    subnet="$(docker network inspect "$nid" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')"
    for s in $subnet; do
      [ -n "$s" ] || continue
      printf '%s\n' "$s" >>"$out"
    done
  done
  # Host IPv4s (macOS ifconfig; also works on many Linux boxes).
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '/inet / { print $2 }' | while read -r ip; do
      case "$ip" in
        ""|127.*|::1) continue ;;
        *.*.*.*) printf '%s/32\n' "$ip" >>"$out" ;;
      esac
    done
  fi
}

# Exit 0 if LAB_SUBNET overlaps something; prints "overlap with <cidr>" on stderr.
subnet_overlaps() {
  local want="$1"
  local tmp cidr
  tmp="$(mktemp)"
  _collect_overlap_cidrs "$tmp"
  while IFS= read -r cidr || [ -n "$cidr" ]; do
    [ -n "$cidr" ] || continue
    if _cidrs_overlap "$want" "$cidr"; then
      echo "overlap with $cidr" >&2
      rm -f "$tmp"
      return 0
    fi
  done <"$tmp"
  rm -f "$tmp"
  return 1
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

bridge_ifname() {
  local custom id
  custom="$(docker network inspect "$LABNET_NAME" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || true)"
  if [ -n "$custom" ] && [ "$custom" != "<no value>" ]; then
    printf '%s\n' "$custom"
    return 0
  fi
  id="$(docker network inspect "$LABNET_NAME" --format '{{.Id}}' | cut -c1-12)"
  printf 'br-%s\n' "$id"
}

# Equivalent of: ip link set labbus type bridge mcast_snooping 0
# The setting resets on Docker Desktop restart or labnet recreate — re-run mac-net.sh after either.
disable_igmp_snooping() {
  local br out rc val
  br="$(bridge_ifname)"
  set +e
  out="$(docker run --rm --privileged --network host \
    -e BR="$br" \
    "$LAB_NET_HELPER_IMAGE" \
    sh -c 'f=/sys/class/net/$BR/bridge/multicast_snooping; [ -w "$f" ] || exit 3; echo 0 > "$f"; cat "$f"' 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 3 ]; then
    die "cannot write /sys/class/net/$br/bridge/multicast_snooping (bridge not visible with --network host?)"
  fi
  if [ "$rc" -ne 0 ]; then
    echo "$out" >&2
    die "failed to disable multicast_snooping on $br (exit $rc)"
  fi
  val="$(printf '%s\n' "$out" | tr -d '\r' | tail -n 1 | tr -d '[:space:]')"
  if [ "$val" != "0" ]; then
    echo "FAIL: multicast_snooping is $val on $br (expected 0)" >&2
    exit 1
  fi
  echo "mac-net: $br mcast_snooping=0 (inside Docker Desktop VM)"
}

teardown_net() {
  local attached
  if ! network_exists; then
    echo "mac-net: $LABNET_NAME not present"
    return 0
  fi
  attached="$(docker network inspect "$LABNET_NAME" --format '{{len .Containers}}')"
  if [ "${attached:-0}" != "0" ]; then
    echo "mac-net: $attached container(s) still attached to $LABNET_NAME — stop/rm them first" >&2
    docker network inspect "$LABNET_NAME" --format '{{range .Containers}}  {{.Name}}{{"\n"}}{{end}}' >&2 || true
    exit 1
  fi
  echo "mac-net: removing docker network $LABNET_NAME"
  docker network rm "$LABNET_NAME"
  echo "teardown done"
}

if [ "$TEARDOWN" -eq 1 ]; then
  teardown_net
  exit 0
fi

echo "note: no --install-boot / --enable-docker on macOS — use Docker Desktop"
echo "  'Start Docker Desktop when you sign in' plus restart: unless-stopped for containers"

if network_exists; then
  verify_existing
else
  if subnet_overlaps "$LAB_SUBNET"; then
    echo "FAIL: $LAB_SUBNET overlaps an existing Docker network or host address — pick another LAB_SUBNET" >&2
    exit 1
  fi
  echo "mac-net: creating docker bridge $LABNET_NAME (subnet=$LAB_SUBNET gateway=$LAB_BRIDGE_GATEWAY)"
  # LAB_GATEWAY is host.docker.internal for socat — use LAB_BRIDGE_GATEWAY for the Docker IPAM gateway.
  docker network create \
    -d bridge \
    --subnet "$LAB_SUBNET" \
    --gateway "$LAB_BRIDGE_GATEWAY" \
    "$LABNET_NAME"
  echo "created $LABNET_NAME (bridge, $LAB_SUBNET)"
fi

disable_igmp_snooping

BR_NAME="$(bridge_ifname)"

echo ""
echo "ready (macOS / Docker Desktop):"
echo "  network=$LABNET_NAME  bridge=$BR_NAME  snooping=0  subnet=$LAB_SUBNET"
echo "  simulator IP: $LAB_SIM_IP"
echo "  console after simulator is up: http://localhost:${LAB_SIM_CONSOLE_PORT}/"
echo "  next:"
echo "    1) Phase 1 multicast test (same throwaway containers as README)"
echo "    2) docker compose --env-file lab.env build simulator"
echo "    3) ./scripts/build-car.sh"
echo "    4) docker compose -f docker-compose.yml -f docker-compose.mac.yml --env-file lab.env up -d simulator"
echo "    5) ./scripts/up-car.sh --vin <VIN> --apps <family>"
