#!/bin/bash
# Build hbbs with the signed-in-clients handshake patch.
#
# Deliberately frugal: this ran on a NAS that also serves PostgreSQL, Redis,
# ClickHouse and MinIO, and an unrestricted cargo build took the whole box down
# twice. One codegen job, low priority, capped address space.
set -x

# 2 GB is NOT enough — the final link dies with "Cannot allocate memory".
ulimit -v 3600000 || true
export CARGO_BUILD_JOBS=1
export CARGO_HOME=${CARGO_HOME:-/work/rdbuild/cargo}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-/work/rdbuild/target}
export DEBIAN_FRONTEND=noninteractive
# Cheaper linking: no LTO, no debug info, more codegen units => lower peak RSS.
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_DEBUG=0
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CARGO_PROFILE_RELEASE_INCREMENTAL=false

WORK=${WORK:-/work/rdbuild}
PATCH=${PATCH:-$WORK/0001-secure-handshake-for-signed-in-clients.patch}
mkdir -p "$WORK"
cd "$WORK" || exit 1

echo "=== deps ==="
apt-get update -qq
apt-get install -y -qq git pkg-config libssl-dev build-essential >/dev/null 2>&1

if [ ! -d src-tree ]; then
  echo "=== clone ==="
  nice -n 19 git clone --depth 1 --recursive https://github.com/rustdesk/rustdesk-server.git src-tree || exit 1
fi

echo "=== patch ==="
cd src-tree
git apply --check "$PATCH" && git apply "$PATCH" || echo "patch already applied or failed - check manually"
grep -c "secure_handshake" src/rendezvous_server.rs

echo "=== build ==="
nice -n 19 cargo build --release --bin hbbs
RC=$?
echo "cargo exit: $RC"
if [ $RC -eq 0 ]; then
  cp "$CARGO_TARGET_DIR/release/hbbs" "$WORK/hbbs-patched"
  sha256sum "$WORK/hbbs-patched"
  ls -la "$WORK/hbbs-patched"
fi
echo "BUILD_DONE rc=$RC"
