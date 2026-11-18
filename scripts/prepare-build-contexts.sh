#!/usr/bin/env bash
# Stage filtered Keystone/Pilot trees under .build-contexts/ for car image builds.
# Exclude lists live in vehicle-lab/dockerignores/ — no .dockerignore needed in those repos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$LAB_DIR/.." && pwd)"
DEST="$LAB_DIR/.build-contexts"
EXCLUDES="$LAB_DIR/dockerignores"

KEYSTONE_SRC="${KEYSTONE_SRC:-$ROOT/keystone}"
PILOT_SRC="${PILOT_SRC:-$ROOT/pilot}"

die() { echo "prepare-build-contexts: $*" >&2; exit 2; }

command -v rsync >/dev/null 2>&1 || die "rsync is required"
[[ -d "$KEYSTONE_SRC" ]] || die "missing Keystone checkout: $KEYSTONE_SRC"
[[ -d "$PILOT_SRC" ]] || die "missing Pilot checkout: $PILOT_SRC"
[[ -f "$EXCLUDES/keystone.excludes" ]] || die "missing $EXCLUDES/keystone.excludes"
[[ -f "$EXCLUDES/pilot.excludes" ]] || die "missing $EXCLUDES/pilot.excludes"

mkdir -p "$DEST/keystone" "$DEST/pilot"

echo "prepare-build-contexts: keystone $KEYSTONE_SRC -> $DEST/keystone"
rsync -a --delete --exclude-from="$EXCLUDES/keystone.excludes" \
  "$KEYSTONE_SRC"/ "$DEST/keystone"/

echo "prepare-build-contexts: pilot $PILOT_SRC -> $DEST/pilot"
rsync -a --delete --exclude-from="$EXCLUDES/pilot.excludes" \
  "$PILOT_SRC"/ "$DEST/pilot"/

# Sanity: Keystone release workspace lists tests/verify/tools/fake_pilot in Cargo.toml.
[[ -d "$DEST/keystone/tests/verify/tools/fake_pilot" ]] || \
  die "staged keystone missing tests/verify/tools/fake_pilot — check excludes"
[[ -f "$DEST/pilot/pyproject.toml" ]] || die "staged pilot missing pyproject.toml"

du -sh "$DEST/keystone" "$DEST/pilot" | sed 's/^/prepare-build-contexts: /'
echo "prepare-build-contexts: done"
