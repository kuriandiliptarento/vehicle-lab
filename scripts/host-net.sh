#!/usr/bin/env bash
# Create labbus, disable IGMP snooping, create host macvlan shim, create Docker macvlan.
#
#   sudo ./scripts/host-net.sh
#   sudo ./scripts/host-net.sh --enable-docker
#   sudo ./scripts/host-net.sh --install-boot
#   sudo ./scripts/host-net.sh teardown
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${LAB_ENV:-$LAB_DIR/lab.env}"
EXAMPLE_ENV="$LAB_DIR/lab.env.example"

ENABLE_DOCKER=0
INSTALL_BOOT=0
TEARDOWN=0

usage() {
  cat <<'EOF' >&2
Usage: sudo ./scripts/host-net.sh [--enable-docker] [--install-boot] [teardown]

  (default)       create labbus, labshim, and Docker macvlan labnet
  --enable-docker systemctl enable --now docker
  --install-boot  install a oneshot unit that re-runs this script at boot
  teardown        remove labnet, labshim, and labbus
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    --enable-docker) ENABLE_DOCKER=1; shift ;;
    --install-boot) INSTALL_BOOT=1; shift ;;
    teardown) TEARDOWN=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root (sudo)" >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$EXAMPLE_ENV" ]]; then
    echo "missing $ENV_FILE — copy from lab.env.example first:" >&2
    echo "  cp $EXAMPLE_ENV $ENV_FILE" >&2
  else
    echo "missing $ENV_FILE" >&2
  fi
  exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

LABBUS_NAME="${LABBUS_NAME:-labbus}"
LABSHIM_NAME="${LABSHIM_NAME:-labshim}"
LABNET_NAME="${LABNET_NAME:-labnet}"
LAB_SUBNET="${LAB_SUBNET:-10.74.0.0/24}"
LAB_GATEWAY="${LAB_GATEWAY:-10.74.0.1}"

subnet_overlaps() {
  local want="$1"
  local cidr
  # Refuse if any local address is already in LAB_SUBNET.
  while read -r cidr; do
    [[ -z "$cidr" ]] && continue
    if python3 - "$want" "$cidr" <<'PY'
import ipaddress, sys
want = ipaddress.ip_network(sys.argv[1], strict=False)
have = ipaddress.ip_network(sys.argv[2], strict=False)
sys.exit(0 if want.overlaps(have) else 1)
PY
    then
      echo "overlap with $cidr" >&2
      return 0
    fi
  done < <(ip -4 -o addr show | awk '{print $4}')
  return 1
}

teardown_net() {
  if docker network inspect "$LABNET_NAME" >/dev/null 2>&1; then
    echo "removing docker network $LABNET_NAME"
    docker network rm "$LABNET_NAME" || true
  fi
  if ip link show "$LABSHIM_NAME" >/dev/null 2>&1; then
    echo "removing $LABSHIM_NAME"
    ip link delete "$LABSHIM_NAME" || true
  fi
  DUMMY_NAME="${LABBUS_DUMMY:-${LABBUS_NAME}-dummy}"
  if ip link show "$DUMMY_NAME" >/dev/null 2>&1; then
    echo "removing $DUMMY_NAME"
    ip link delete "$DUMMY_NAME" || true
  fi
  if ip link show "$LABBUS_NAME" >/dev/null 2>&1; then
    echo "removing $LABBUS_NAME"
    ip link delete "$LABBUS_NAME" || true
  fi
  iptables -t nat -D POSTROUTING -s "$LAB_SUBNET" ! -d "$LAB_SUBNET" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -s "$LAB_SUBNET" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -d "$LAB_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  echo "teardown done"
}

install_boot_unit() {
  local unit=/etc/systemd/system/vehicle-lab-host-net.service
  cat >"$unit" <<EOF
[Unit]
Description=Vehicle lab labbus + macvlan shim
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_DIR/host-net.sh
Environment=LAB_ENV=$ENV_FILE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable vehicle-lab-host-net.service
  echo "installed and enabled $unit"
}

if [[ "$TEARDOWN" -eq 1 ]]; then
  teardown_net
  exit 0
fi

if [[ "$ENABLE_DOCKER" -eq 1 ]]; then
  systemctl enable --now docker
  echo "docker enabled and started"
else
  echo "note: containers return after reboot only when docker is enabled:"
  echo "  sudo systemctl enable --now docker"
  echo "  (or re-run with --enable-docker)"
fi

if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    echo "docker is not usable (daemon down or permission)" >&2
    exit 1
  fi
else
  echo "docker not found on PATH" >&2
  exit 1
fi

# Overlap check only when creating fresh interfaces that would claim LAB_GATEWAY.
if ! ip link show "$LABSHIM_NAME" >/dev/null 2>&1; then
  if subnet_overlaps "$LAB_SUBNET"; then
    echo "FAIL: $LAB_SUBNET overlaps an existing local address — pick another LAB_SUBNET" >&2
    ip -4 -o addr show >&2
    exit 1
  fi
fi

DUMMY_NAME="${LABBUS_DUMMY:-${LABBUS_NAME}-dummy}"

if ! ip link show "$LABBUS_NAME" >/dev/null 2>&1; then
  echo "creating bridge $LABBUS_NAME"
  ip link add name "$LABBUS_NAME" type bridge
fi
ip link set dev "$LABBUS_NAME" type bridge mcast_snooping 0

# A bridge with no ports stays NO-CARRIER; macvlan peers then cannot talk.
# Enslave a dummy so labbus gets carrier (no address on the bridge itself).
if ! ip link show "$DUMMY_NAME" >/dev/null 2>&1; then
  echo "creating dummy $DUMMY_NAME for bridge carrier"
  ip link add "$DUMMY_NAME" type dummy
fi
ip link set "$DUMMY_NAME" up
# Master may already be set; ignore "Device or resource busy" / already enslaved.
ip link set "$DUMMY_NAME" master "$LABBUS_NAME" 2>/dev/null || true
ip link set "$LABBUS_NAME" up

# Confirm snooping is off.
if [[ -r "/sys/class/net/$LABBUS_NAME/bridge/multicast_snooping" ]]; then
  snooping="$(cat "/sys/class/net/$LABBUS_NAME/bridge/multicast_snooping")"
  if [[ "$snooping" != "0" ]]; then
    echo "FAIL: mcast_snooping is $snooping on $LABBUS_NAME (expected 0)" >&2
    exit 1
  fi
fi
echo "$LABBUS_NAME up, mcast_snooping=0, carrier via $DUMMY_NAME (no address on the bridge)"

if ! ip link show "$LABSHIM_NAME" >/dev/null 2>&1; then
  echo "creating host shim $LABSHIM_NAME ($LAB_GATEWAY)"
  ip link add "$LABSHIM_NAME" link "$LABBUS_NAME" type macvlan mode bridge
  ip addr add "$LAB_GATEWAY/24" dev "$LABSHIM_NAME"
fi
ip link set "$LABSHIM_NAME" up
echo "$LABSHIM_NAME up at $LAB_GATEWAY"

# Containers are single-homed on labnet (gateway = labshim). Without host NAT they
# cannot reach Nominatim / OSRM (places search + Drive routing). Keep one NIC on
# the car/sim for multicast; egress is masqueraded on the host.
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! iptables -t nat -C POSTROUTING -s "$LAB_SUBNET" ! -d "$LAB_SUBNET" -j MASQUERADE 2>/dev/null; then
  iptables -t nat -A POSTROUTING -s "$LAB_SUBNET" ! -d "$LAB_SUBNET" -j MASQUERADE
fi
if ! iptables -C FORWARD -s "$LAB_SUBNET" -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -s "$LAB_SUBNET" -j ACCEPT
fi
if ! iptables -C FORWARD -d "$LAB_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
  iptables -A FORWARD -d "$LAB_SUBNET" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi
echo "egress: ip_forward=1, MASQUERADE $LAB_SUBNET → host uplink"

if docker network inspect "$LABNET_NAME" >/dev/null 2>&1; then
  echo "docker network $LABNET_NAME already exists"
else
  echo "creating docker macvlan $LABNET_NAME (parent=$LABBUS_NAME, mode=bridge)"
  docker network create \
    -d macvlan \
    --subnet="$LAB_SUBNET" \
    --gateway="$LAB_GATEWAY" \
    -o parent="$LABBUS_NAME" \
    -o macvlan_mode=bridge \
    "$LABNET_NAME"
fi

if [[ "$INSTALL_BOOT" -eq 1 ]]; then
  install_boot_unit
fi

echo ""
echo "ready:"
echo "  bridge=$LABBUS_NAME  shim=$LABSHIM_NAME($LAB_GATEWAY)  docker=$LABNET_NAME"
echo "  simulator IP (compose): ${LAB_SIM_IP:-10.74.0.2}"
echo "  console after simulator is up: curl http://${LAB_SIM_IP:-10.74.0.2}:8090/"
