#!/usr/bin/env bash
# build_server.sh — build zksync-os-server binary
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/repos/zksync-os-server"

log() { echo "[build_server] $*"; }

if [ ! -d "$SERVER_DIR" ]; then
  echo "ERROR: zksync-os-server not cloned. Run scripts/clone_repos.sh first."
  exit 1
fi

# Ensure Rust is on PATH
source "$HOME/.cargo/env" 2>/dev/null || true

log "=== Building zksync-os-server ==="
log "Source: $SERVER_DIR"

cd "$SERVER_DIR"

# Check for Cargo.toml
if [ ! -f "Cargo.toml" ]; then
  log "ERROR: No Cargo.toml found in $SERVER_DIR"
  log "Repository contents:"
  ls -la
  exit 1
fi

log "Cargo.toml found. Building release binary..."
log "This may take several minutes on first build."

cargo build --release 2>&1 | tail -20

# Locate built binary
BINARY_CANDIDATES=(
  "target/release/zksync-os-server"
  "target/release/server"
  "target/release/zksync_os_server"
)

BINARY=""
for candidate in "${BINARY_CANDIDATES[@]}"; do
  if [ -f "$SERVER_DIR/$candidate" ]; then
    BINARY="$SERVER_DIR/$candidate"
    break
  fi
done

if [ -z "$BINARY" ]; then
  log "WARNING: could not auto-detect built binary. Checking target/release/..."
  ls "$SERVER_DIR/target/release/" | grep -v '\.d$' | head -20
  log "Set SERVER_BINARY manually in start_lab.sh if needed."
else
  log "Binary found: $BINARY"
  # Write the binary path to a config file for start_lab.sh
  echo "$BINARY" > "$ROOT/.server_binary_path"
  log "Binary path saved to .server_binary_path"
fi

log "=== Build complete ==="
