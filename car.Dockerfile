# syntax=docker/dockerfile:1.6
# Build with Compose additional_contexts for keystone, pilot, and sim-apps.
#
#   docker compose build car

############################
# Keystone release binary
############################
FROM rust:1-bookworm AS keystone-build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
COPY --from=keystone . .
RUN cargo build -p keystone --release

############################
# Pilot .venv (make run)
############################
FROM python:3.11-bookworm AS pilot-build
WORKDIR /pilot
RUN apt-get update && apt-get install -y --no-install-recommends \
    make \
    && rm -rf /var/lib/apt/lists/*
COPY --from=pilot pyproject.toml poetry.lock ./
COPY --from=pilot src/ ./src/
COPY --from=pilot Makefile ./
COPY --from=pilot .env.example ./.env.example
RUN python3 -m venv .venv \
    && .venv/bin/pip install --upgrade pip poetry \
    && POETRY_VIRTUALENVS_CREATE=false .venv/bin/poetry install --only main --no-root \
    && test -x .venv/bin/python

############################
# Runtime: Keystone + Pilot + tele + ro
############################
FROM python:3.11-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    make \
    ca-certificates \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Keystone binary + checkout (run-lab-supervisor.sh resolves ROOT from its path)
COPY --from=keystone-build /src/target/release/keystone /usr/local/bin/keystone
RUN chmod +x /usr/local/bin/keystone
COPY --from=keystone deploy/scripts/run-lab-supervisor.sh /keystone/deploy/scripts/run-lab-supervisor.sh
RUN chmod +x /keystone/deploy/scripts/run-lab-supervisor.sh \
    && mkdir -p /keystone/deploy/scripts

# Pilot tree with .venv for `make run`
COPY --from=pilot-build /pilot /pilot
COPY --from=pilot .env.example /pilot/.env.example

# All sim-apps families; DBC_FAMILY selects which pair the entrypoint starts.
WORKDIR /apps
COPY --from=sim-apps gai_EV/tele/requirements.txt /tmp/req-gai_EV-tele.txt
COPY --from=sim-apps gai_EV/ro/requirements.txt /tmp/req-gai_EV-ro.txt
COPY --from=sim-apps gai_ICE/tele/requirements.txt /tmp/req-gai_ICE-tele.txt
COPY --from=sim-apps gai_ICE/ro/requirements.txt /tmp/req-gai_ICE-ro.txt
COPY --from=sim-apps prod_EV/tele/requirements.txt /tmp/req-prod_EV-tele.txt
COPY --from=sim-apps prod_EV/ro/requirements.txt /tmp/req-prod_EV-ro.txt
COPY --from=sim-apps prod_ICE/tele/requirements.txt /tmp/req-prod_ICE-tele.txt
COPY --from=sim-apps prod_ICE/ro/requirements.txt /tmp/req-prod_ICE-ro.txt
RUN pip install --no-cache-dir \
      -r /tmp/req-gai_EV-tele.txt \
      -r /tmp/req-gai_EV-ro.txt \
      -r /tmp/req-gai_ICE-tele.txt \
      -r /tmp/req-gai_ICE-ro.txt \
      -r /tmp/req-prod_EV-tele.txt \
      -r /tmp/req-prod_EV-ro.txt \
      -r /tmp/req-prod_ICE-tele.txt \
      -r /tmp/req-prod_ICE-ro.txt \
    && rm -f /tmp/req-*.txt

COPY --from=sim-apps gai_EV/tele/ /apps/gai_EV/tele/
COPY --from=sim-apps gai_EV/ro/ /apps/gai_EV/ro/
COPY --from=sim-apps gai_ICE/tele/ /apps/gai_ICE/tele/
COPY --from=sim-apps gai_ICE/ro/ /apps/gai_ICE/ro/
COPY --from=sim-apps prod_EV/tele/ /apps/prod_EV/tele/
COPY --from=sim-apps prod_EV/ro/ /apps/prod_EV/ro/
COPY --from=sim-apps prod_ICE/tele/ /apps/prod_ICE/tele/
COPY --from=sim-apps prod_ICE/ro/ /apps/prod_ICE/ro/

COPY car-entrypoint.sh /usr/local/bin/car-entrypoint.sh
RUN chmod +x /usr/local/bin/car-entrypoint.sh

ENV PYTHONUNBUFFERED=1
ENV KEYSTONE_BIN=/usr/local/bin/keystone

VOLUME ["/var/lib/keystone", "/var/lib/pilot", "/var/lib/car"]

ENTRYPOINT ["/usr/local/bin/car-entrypoint.sh"]
