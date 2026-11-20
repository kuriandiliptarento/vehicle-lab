# Vehicle lab Docker layout

One multi-car **simulator** container and **one container per VIN** (telemetry, remote-ops, Keystone via `run-lab-supervisor.sh`, Pilot via `make run`) on a shared macvlan L2 segment.

The simulator and apps still meet on the VIN-derived UDP multicast bus (`239.74.x.y` + port). No HTTP proxy to the plant. Pilot talks to tele/ro on `127.0.0.1`. Keystone and Pilot share `/tmp/keystone.sock`.

```
host (labshim 10.74.0.1)
        |
     labbus  (mcast_snooping=0)
        |
   +----+----+--------------------+
   |         |                    |
 sim      car VIN A            car VIN B
 10.74.0.2  (up-car.sh)         (up-car.sh)
```

This guide does **not** record test results. Run each phase and fill your own notes.

## Quick start

Sibling checkouts required next to this folder: `master-vehicle-simulator/`, `keystone/`, `pilot/`, `sim-apps/`. Autrio/EMQX (or your lab Autrio URL) must be reachable at `LAB_GATEWAY` (default `10.74.0.1`).

**Keystone identity** is passed into the car by `up-car.sh` (entrypoint writes in-container supervisor env). Do **not** rely on host `keystone/deploy/scripts/lab-supervisor.local.env`.

| Source | What |
|---|---|
| `lab.env` | Shared lab defaults: `LAB_*`, and optional default `KEYSTONE_*` |
| `up-car.sh` flags | Per car / tenant overrides (flags win over `lab.env`) |

| Flag / env | Purpose |
|---|---|
| `--vin` | VIN (required on CLI; not in `lab.env`) |
| `--tenant-key` / `KEYSTONE_TENANT_KEY` | tenant (differs per org) |
| `--birth-secret` / `KEYSTONE_BIRTH_SECRET` | device birth secret (per device/tenant) |
| `--autrio-url` / `KEYSTONE_AUTRIO_URL` | Autrio URL via labshim (e.g. `http://10.74.0.1:8002`) |
| `--keystore` / `KEYSTONE_KEYSTORE_BACKEND` | usually `file` in the lab |

### Linux

```bash
cd vehicle-lab
cp lab.env.example lab.env
# edit lab.env — at least LAB_* ; optional default KEYSTONE_* for your usual tenant

sudo ./scripts/host-net.sh
docker compose --env-file lab.env build simulator
./scripts/build-car.sh
docker compose --env-file lab.env up -d simulator

# defaults from lab.env:
./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV

# or override tenant/secret on the CLI (same pattern as --vin):
./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV \
  --tenant-key other-org --birth-secret "$SECRET"
# console: http://10.74.0.2:8090/ — add the same VIN + matching DBC
```

### macOS (Docker Desktop)

```bash
cd vehicle-lab
cp lab.env.mac.example lab.env
# edit lab.env — KEYSTONE_* defaults for your tenant

./scripts/mac-net.sh
docker compose --env-file lab.env build simulator
./scripts/build-car.sh
docker compose -f docker-compose.yml -f docker-compose.mac.yml --env-file lab.env up -d simulator

# defaults from lab.env:
./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV

# or override tenant/secret on the CLI (same pattern as --vin):
./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV \
  --tenant-key other-org --birth-secret "$SECRET"
# console: http://localhost:18090/ (from another machine: http://<mac-ip>:18090/)
```

**Caveat:** `up-car.sh` passes `KEYSTONE_BIRTH_SECRET` as a `docker run -e` value, so `docker inspect` on a shared host can read it.

Details, networking, MQTT forward, and phase checks are below.

## Prerequisites

- Linux host with Docker (Compose v2) and BuildKit, **or macOS with Docker Desktop**
- Sibling checkouts: `master-vehicle-simulator/`, `keystone/`, `pilot/`, `sim-apps/` next to this folder
- Root only for Linux host networking (`labbus` / macvlan); macOS uses `./scripts/mac-net.sh` without sudo

```bash
cd vehicle-lab
# Linux:
cp lab.env.example lab.env
# macOS:
# cp lab.env.mac.example lab.env
# edit lab.env — LAB_* / KEYSTONE_* as needed (CLI can override tenant fields)
```

## Host network (once per boot unless `--install-boot`)

```bash
sudo ./scripts/host-net.sh
# optional:
sudo ./scripts/host-net.sh --enable-docker
sudo ./scripts/host-net.sh --install-boot
```

What it creates:

| Object | Role |
|---|---|
| `labbus` | Linux bridge, **no IP**, IGMP snooping off |
| `labbus-dummy` | Dummy port enslaved to `labbus` so the bridge gets **carrier** |
| `labshim` | Host macvlan on `labbus` at `LAB_GATEWAY` (default `10.74.0.1`) |
| `labnet` | Docker macvlan, `parent=labbus`, `macvlan_mode=bridge` |

#### Why `labbus-dummy` (carrier)

A bridge with no member ports stays `NO-CARRIER` / effectively down. Macvlan endpoints (the host shim and every container on `labnet`) then cannot talk: `http://10.74.0.2:8090/` times out even though the simulator console is fine **inside** its own network namespace.

`host-net.sh` enslaves a single dummy interface (`labbus-dummy`) to `labbus` so the bridge has a fake port and gets carrier. The dummy has no IP; neither does `labbus`. Host access is only via `labshim`.

If the console is unreachable from the host, check:

```bash
ip -br link show labbus labbus-dummy labshim
# labbus should not stay NO-CARRIER after host-net.sh
curl -sS -o /dev/null -w '%{http_code}\n' http://10.74.0.2:8090/
# use 10.74.0.2 — not http://127.0.0.1:8090/ (host loopback ≠ container)
```

Teardown:

```bash
sudo ./scripts/host-net.sh teardown
```

Do **not** put an address on `labbus` itself. Host ↔ container traffic uses `labshim`.

#### Internet egress (places search / Drive)

The simulator (and cars) stay **single-homed** on `labnet` so multicast keeps one default interface. Their default gateway is `labshim` (`10.74.0.1`). `host-net.sh` turns on `ip_forward` and adds `MASQUERADE` for `10.74.0.0/24` so Nominatim (places) and OSRM (Drive) can reach the public internet through the host.

Without that NAT the console returns `Network is unreachable` for places search. Re-run `sudo ./scripts/host-net.sh` after a reboot if places fail again (or use `--install-boot`).

### macOS (Docker Desktop)

On macOS, **do not** run `host-net.sh` (`ip` / bridges / macvlan / iptables are Linux-only). Instead:

```bash
./scripts/mac-net.sh
```

What differs from Linux:

| Topic | macOS behavior |
|---|---|
| `labbus` / `labshim` / macvlan | **Not used** |
| `labnet` | Docker **bridge** network (`10.74.0.0/24`), created by `mac-net.sh` |
| Autrio / EMQX | Cars reach the Mac via `host.docker.internal` (`LAB_GATEWAY` / `KEYSTONE_AUTRIO_URL` in `lab.env.mac.example`) |
| Internet egress | Docker Desktop’s NAT — no `host-net.sh` MASQUERADE |
| Operator console | Published host port (default **18090** via `docker-compose.mac.yml`), not `http://10.74.0.2:8090/` |
| IGMP snooping | Cannot be disabled on a Docker bridge — run **Phase 1** first to confirm VIN multicast works |

Teardown: `./scripts/mac-net.sh teardown` (stop/rm attached containers first if needed).

## Build and run

**Linux:**

```bash
docker compose --env-file lab.env build simulator
./scripts/build-car.sh                              # stages keystone/pilot, then builds car image
docker compose --env-file lab.env up -d simulator
```

**macOS:** same build steps; bring the simulator up with the mac override so the console is published:

```bash
docker compose --env-file lab.env build simulator
./scripts/build-car.sh
docker compose -f docker-compose.yml -f docker-compose.mac.yml --env-file lab.env up -d simulator
# console: http://localhost:18090/
```

`car` is build-only (`profiles: [build]`). Compose never starts it. Runtime cars come from `up-car.sh`.

#### Staged Keystone / Pilot contexts

Compose does not read `.dockerignore` from vehicle-lab for sibling contexts, and this lab does not require committing `.dockerignore` into the Keystone or Pilot repos. Instead:

1. Exclude lists live in [`dockerignores/`](dockerignores/) (`keystone.excludes`, `pilot.excludes`).
2. `./scripts/prepare-build-contexts.sh` (called by `build-car.sh`) rsyncs sibling `../keystone` and `../pilot` into gitignored `.build-contexts/`, applying those excludes.
3. `docker-compose.yml` points `additional_contexts` at `.build-contexts/keystone` and `.build-contexts/pilot`.

That staging tree is **one** filtered snapshot used to build the single `vehicle-lab-car:local` image — not per VIN. Multiple cars share that image; wipe `.build-contexts/` anytime and re-run `build-car.sh` before the next image rebuild.

### Cars (VIN + apps + optional tenant on the command line)

Pass VIN and app family to `up-car.sh`. Keystone tenant/secret/Autrio URL default from `lab.env` and can be overridden per car with `--tenant-key`, `--birth-secret`, `--autrio-url` (different tenants need different secrets).

```bash
./scripts/build-car.sh   # once, when the image is missing or Dockerfile / Keystone / Pilot changed

./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV
./scripts/up-car.sh --vin SIMICE23892320001 --apps gai_ICE --ip 10.74.0.20
./scripts/up-car.sh --vin SIMEVP23892320001 --apps prod_EV \
  --tenant-key other-org --birth-secret "$SECRET"
./scripts/up-car.sh --vin SIMICEP2389230001 --apps prod_ICE --ip 10.74.0.21
```

| `--apps` | tele port | ro port | typical simulator car / DBC |
|---|---|---|---|
| `gai_EV` | 48211 | 48311 | `gai_EV.dbc` / `configs/cars/ev.yaml` |
| `gai_ICE` | 48212 | 48312 | `gai_ICE.dbc` / `configs/cars/ice.yaml` |
| `prod_EV` | 48213 | 48313 | `prod_EV.dbc` / `configs/cars/ev-prod.yaml` |
| `prod_ICE` | 48214 | 48314 | `prod_ICE.dbc` / `configs/cars/ice-prod.yaml` |

Aliases accepted: `gaiev`, `gai-ice`, `prod-ev`, `prod-ice`. Default IP is the next free address in `10.74.0.32–63`. Container name defaults to `vehicle-lab-car-<VIN>`.

**App `data_dir` / locks:** Telemetry and remote-ops each flock `data_dir/.lock` so a second copy of the same app cannot start. In the car they run **side by side**, so they must not share one directory. The entrypoint sets `data_dir` to `/var/lib/car/tele` and `/var/lib/car/ro`. If you add another in-car app that uses the same lock pattern, give it its own path under `/var/lib/car/<app>` in `car-entrypoint.sh` (`write_app_json`); a shared dir will leave the loser crash-looping and Pilot commands to that port will fail with connection errors.

Then add the **same VIN** in the simulator console with the matching DBC so the plant joins that bus.

| Service / tool | Address | Notes |
|---|---|---|
| `simulator` | `10.74.0.2` | Console `http://10.74.0.2:8090/` via `labshim` |
| `car` (Compose) | — | build-only image `vehicle-lab-car:local` |
| `up-car.sh` | chosen / auto | one container per VIN + `--apps` |

Volumes (not shared across VINs): `sim-state`, per-VIN `vehicle-lab-car-<VIN>-*`.

### Process starts inside a car container

1. Entrypoint writes `keystone/deploy/scripts/lab-supervisor.local.env` (not baked into the image), including `KEYSTONE_PILOT_RUNTIME=stub`.
2. MQTT localhost forward (`socat`): `127.0.0.1:1883` → `LAB_GATEWAY:1883` (see below).
3. Background: `run-lab-supervisor.sh` → `exec $KEYSTONE_BIN` (`/usr/local/bin/keystone`).
4. Wait for `/tmp/keystone.sock`.
5. Telemetry + remote-ops (`python3 -m …`) with separate `data_dir`s (`/var/lib/car/tele` and `/var/lib/car/ro`) so their `data_dir/.lock` files do not collide.
6. Write `/pilot/.env` with `KEYSTONE_IPC_PATH=/tmp/keystone.sock`, then `make -C /pilot run`.

Single-homed on `labnet`: Keystone cannot reach Autrio at the host’s `127.0.0.1`. Point `KEYSTONE_AUTRIO_URL` at something reachable via `labshim` (example uses `http://10.74.0.1:8002`).

**MQTT / Autrio `localhost` broker:** Autrio bootstrap currently returns `mqtt_broker_host=localhost`. That works for Keystone on the host (EMQX on the same machine) but fails inside a labnet car (`broker_unreachable`). The car entrypoint therefore starts `socat` so in-container `localhost:1883` reaches EMQX on `LAB_GATEWAY` (labshim, default `10.74.0.1`). This is vehicle-lab only — no Keystone/Pilot/app source change, and it does not bind MQTT on the host. Setup steps are unchanged (`up-car.sh` already passes `LAB_GATEWAY`). If Autrio later advertises a lab-reachable broker (or Keystone gains a real broker-host override), remove the `socat` forward from `car-entrypoint.sh`.

### Keystone and Pilot (lab vs field)

**Field / intended device path:** Keystone is host authority. It probes a Pilot OCI engine (Docker), then starts Pilot as a **sibling container**, binds the Runtime API socket, and (by default) uses `--network host`. Telemetry/remote-ops on the vehicle are not co-located in that same process tree the way this lab packs them.

**This lab (for now):** Keystone, Pilot, telemetry, and remote-ops share **one car container** and one network namespace so Pilot can keep using `127.0.0.1` for tele/ro. The entrypoint starts Pilot with `make run`. `up-car.sh` sets `KEYSTONE_PILOT_RUNTIME=stub` so Keystone skips the Docker OCI probe and does not try to `docker run` Pilot. Without stub, supervisor exits with `pilot_runtime_unsupported` (no docker socket in the car) and the car restart-loops before the socket exists.

To move closer to the intended OCI path later you would need at least:

- Docker CLI + mounted docker socket (or another usable engine) in/near Keystone
- A Pilot image and an LKG / pin Keystone can ensure
- Launch `network_mode` that keeps Pilot in the **car** netns (default `host` would put Pilot on the host stack and break localhost tele/ro)
- Entrypoint that no longer runs `make run` (Keystone owns Pilot lifecycle)

Until then, stub + in-container `make run` is the supported lab choice. Do not mount docker.sock unless you are deliberately implementing that OCI path.

## Debug helpers

```bash
# VIN → multicast group + port (same checksum as the plant)
python3 scripts/bus-id.py SIMEV238923200001 SIMEV238923200002

docker logs -f vehicle-lab-simulator
docker logs -f vehicle-lab-car-SIMEV238923200001
docker exec vehicle-lab-car-SIMEV238923200001 ss -ltn | grep -E '48211|48311'
docker exec vehicle-lab-car-SIMEV238923200001 ls -l /tmp/keystone.sock
docker exec vehicle-lab-car-SIMEV238923200001 ps aux
```

---

## Phase 1 — Networking foundation

**Goal:** sibling endpoints on `labnet` exchange UDP multicast and unicast.

```bash
# Linux:
sudo ./scripts/host-net.sh
# macOS (Docker Desktop):
# ./scripts/mac-net.sh

# Two throwaway containers on labnet
docker run -d --rm --name mcast-a --network labnet --ip 10.74.0.10 python:3.11-slim sleep 3600
docker run -d --rm --name mcast-b --network labnet --ip 10.74.0.11 python:3.11-slim sleep 3600

# Receiver (join group) — leave this running in one terminal
docker exec -it mcast-b python3 -c '
import socket, struct
GROUP, PORT = "239.74.1.1", 55001
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", PORT))
mreq = struct.pack("=4s4s", socket.inet_aton(GROUP), socket.inet_aton("0.0.0.0"))
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
print("waiting", flush=True)
data, addr = s.recvfrom(65535)
print("got", data, "from", addr, flush=True)
'

# Sender (second terminal)
docker exec mcast-a python3 -c '
import socket
GROUP, PORT = "239.74.1.1", 55001
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
s.sendto(b"labbus-ok", (GROUP, PORT))
print("sent", flush=True)
'

# Unicast: UDP echo between siblings (no ping package required)
docker exec -d mcast-b python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("0.0.0.0", 9))
data, addr = s.recvfrom(64)
s.sendto(b"pong:"+data, addr)
print("echoed", data, "to", addr, flush=True)
'
docker exec mcast-a python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(b"ping", ("10.74.0.11", 9))
print(s.recvfrom(64), flush=True)
'
```


**Pass when:** receiver prints `got b'labbus-ok'`; ping succeeds.

**Your result:** _(empty)_

Cleanup: `docker rm -f mcast-a mcast-b`

---

## Phase 2 — Host connectivity

**Goal:** host reaches the simulator console.

**Linux** — through `labshim` (not an address on `labbus`):

```bash
docker compose --env-file lab.env up -d simulator
# wait for "console http://0.0.0.0:8090/"
curl -sS -o /dev/null -w "%{http_code}\n" http://10.74.0.2:8090/
# expect 200
ip addr show labshim
# labbus must have no IPv4 address
ip -4 addr show labbus || true
```

**Pass when (Linux):** curl returns `200`; `labshim` has `10.74.0.1`; bridge has no IPv4.

**macOS** — through the published port (no `labshim` / `ip` checks):

```bash
docker compose -f docker-compose.yml -f docker-compose.mac.yml --env-file lab.env up -d simulator
curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:18090/
# expect 200
```

**Pass when (macOS):** curl returns `200`.

**Your result:** _(empty)_

---

## Phase 3 — Simulator deployment

```bash
docker compose --env-file lab.env up -d simulator
docker logs vehicle-lab-simulator | head
python3 scripts/bus-id.py SIMEV238923200001 SIMEV238923200002
# Open console — Linux: http://10.74.0.2:8090/ ; macOS: http://localhost:18090/
# add a car (DBC + VIN), confirm it appears
# Optional: from a throwaway container, join that VIN's group/port and sniff frames
```

**Pass when:** console loads; roster/state under volume `sim-state`; two VINs show different group/port.

**Your result:** _(empty)_

---

## Phase 4 — Single-car deployment

```bash
./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV
NAME=vehicle-lab-car-SIMEV238923200001
docker logs -f "$NAME"   # Keystone socket, then tele/ro/pilot
docker exec "$NAME" ss -ltn
# expect 127.0.0.1:48211 and 127.0.0.1:48311 for gai_EV
docker exec "$NAME" test -S /tmp/keystone.sock && echo sock_ok
# In the simulator console, add the same VIN + matching DBC and Drive if needed.
docker exec "$NAME" python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:48211/health').read())"
```

**Pass when:** four processes up; localhost tele/ro listening; socket exists; car receives that VIN’s multicast (health/telemetry advances when the plant is on the bus).

**Your result:** _(empty)_

---

## Phase 5 — Multi-car deployment

```bash
./scripts/up-car.sh --vin SIMEV238923200001 --apps gai_EV
./scripts/up-car.sh --vin SIMICE23892320001 --apps gai_ICE
docker exec vehicle-lab-car-SIMEV238923200001 ss -ltn | grep 48211
docker exec vehicle-lab-car-SIMICE23892320001 ss -ltn | grep 48212
# each namespace binds its own family's localhost ports
docker volume ls | grep vehicle-lab
python3 scripts/bus-id.py SIMEV238923200001 SIMICE23892320001
```

**Pass when:** both cars are up; volumes are separate; different VINs use different multicast group/port; app ports match the family table.

**Your result:** _(empty)_

---

## Phase 6 — Recovery

```bash
docker restart vehicle-lab-car-SIMEV238923200001
docker restart vehicle-lab-simulator
# After restart: console still up; car roster restored from sim-state; car processes back
```

**Linux** — durable host-net + Docker across reboot:

```bash
systemctl is-enabled docker
# Reboot host only after host-net is durable:
#   sudo ./scripts/host-net.sh --install-boot
#   sudo ./scripts/host-net.sh --enable-docker
# Then reboot and confirm labbus/labshim/labnet + containers return.
```

**macOS:** `--install-boot` / `--enable-docker` do **not** apply. The Docker bridge `labnet` persists across Docker Desktop restarts; containers use `restart: unless-stopped`. Re-run `./scripts/mac-net.sh` only if the network was removed.

**Pass when:** individual restarts recover; after reboot (Linux with boot unit + docker enabled, or macOS with Docker Desktop back) containers and volumes persist.

**Your result:** _(empty)_

---

## Layout

| Path | Role |
|---|---|
| [docker-compose.yml](docker-compose.yml) | simulator + build-only `car` image |
| [docker-compose.mac.yml](docker-compose.mac.yml) | macOS override: publish console `${LAB_SIM_CONSOLE_PORT:-18090}:8090` |
| [car.Dockerfile](car.Dockerfile) | Keystone binary + Pilot `.venv` + all four sim-apps families |
| [dockerignores/](dockerignores/) | rsync excludes for staged Keystone/Pilot contexts |
| [scripts/prepare-build-contexts.sh](scripts/prepare-build-contexts.sh) | rsync siblings → `.build-contexts/` |
| [scripts/build-car.sh](scripts/build-car.sh) | prepare contexts + `compose build car` |
| [scripts/up-car.sh](scripts/up-car.sh) | one container per VIN: `--vin` + `--apps` |
| [car-entrypoint.sh](car-entrypoint.sh) | process supervisor |
| [scripts/host-net.sh](scripts/host-net.sh) | Linux: `labbus` / shim / macvlan `labnet` |
| [scripts/mac-net.sh](scripts/mac-net.sh) | macOS: Docker bridge `labnet` (no sudo) |
| [lab.env.example](lab.env.example) | Linux addresses + optional Keystone defaults |
| [lab.env.mac.example](lab.env.mac.example) | macOS: `host.docker.internal` + console port 18090 |
| [../master-vehicle-simulator/Dockerfile](../master-vehicle-simulator/Dockerfile) | fleet + console on `0.0.0.0:8090` |
