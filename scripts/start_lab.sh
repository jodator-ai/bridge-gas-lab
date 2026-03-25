#!/usr/bin/env bash
# start_lab.sh — start Anvil (L1) and zksync-os-server (L2)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/repos/zksync-os-server"
PIDS_DIR="$ROOT/.pids"
LOGS_DIR="$ROOT/.logs"

mkdir -p "$PIDS_DIR" "$LOGS_DIR"

L1_RPC="http://localhost:8545"
L2_RPC="http://localhost:3050"
L1_PORT=8545
L2_PORT=3050

log() { echo "[start_lab] $*"; }

wait_for_rpc() {
  local url="$1"
  local name="$2"
  local retries=60
  log "Waiting for $name at $url..."
  for i in $(seq 1 $retries); do
    if curl -sf -X POST "$url" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
        > /dev/null 2>&1; then
      log "$name is up (attempt $i)"
      return 0
    fi
    sleep 2
  done
  log "ERROR: $name did not come up after $((retries * 2)) seconds"
  return 1
}

# ── Stop any running instances ─────────────────────────────────────────────────
"$ROOT/scripts/stop_lab.sh" 2>/dev/null || true

# ── Find L1 state snapshot ─────────────────────────────────────────────────────
# Look for l1-state.json.gz in zksync-os-server local-chains dirs
L1_STATE_GZ=""
if [ -d "$SERVER_DIR/local-chains" ]; then
  L1_STATE_GZ=$(find "$SERVER_DIR/local-chains" -name "l1-state.json.gz" | head -1)
fi

if [ -z "$L1_STATE_GZ" ]; then
  log "WARNING: l1-state.json.gz not found in $SERVER_DIR/local-chains"
  log "Starting Anvil without a snapshot (fresh state)"
  L1_STATE_JSON=""
else
  log "Found L1 state snapshot: $L1_STATE_GZ"
  L1_STATE_JSON="${L1_STATE_GZ%.gz}"
  if [ ! -f "$L1_STATE_JSON" ]; then
    log "Decompressing..."
    gunzip -k "$L1_STATE_GZ"
    log "Decompressed to: $L1_STATE_JSON"
  else
    log "Already decompressed: $L1_STATE_JSON"
  fi
fi

# ── Start Anvil (L1) ───────────────────────────────────────────────────────────
log "Starting Anvil on port $L1_PORT..."

ANVIL_CMD="anvil --port $L1_PORT --chain-id 9 --block-time 1"

if [ -n "$L1_STATE_JSON" ]; then
  ANVIL_CMD="$ANVIL_CMD --load-state $L1_STATE_JSON"
  log "Loading state from: $L1_STATE_JSON"
fi

# shellcheck disable=SC2086
nohup $ANVIL_CMD > "$LOGS_DIR/anvil.log" 2>&1 &
ANVIL_PID=$!
echo "$ANVIL_PID" > "$PIDS_DIR/anvil.pid"
log "Anvil PID: $ANVIL_PID"

# ── Start zksync-os-server (L2) ───────────────────────────────────────────────
# Determine binary
if [ -f "$ROOT/.server_binary_path" ]; then
  SERVER_BINARY=$(cat "$ROOT/.server_binary_path")
elif [ -f "$SERVER_DIR/target/release/zksync-os-server" ]; then
  SERVER_BINARY="$SERVER_DIR/target/release/zksync-os-server"
elif [ -f "$SERVER_DIR/run_local.sh" ]; then
  # Use the repo's own run script
  SERVER_BINARY=""
fi

# Find local-chain config
LOCAL_CHAIN_CONFIG=""
if [ -d "$SERVER_DIR/local-chains" ]; then
  # Prefer a config that looks like a default/single chain
  LOCAL_CHAIN_CONFIG=$(find "$SERVER_DIR/local-chains" -name "*.yaml" -o -name "*.toml" -o -name "*.json" \
    | grep -v 'l1-state' | head -1)
fi

log "Starting zksync-os-server on port $L2_PORT..."

if [ -f "$SERVER_DIR/run_local.sh" ]; then
  log "Using run_local.sh from repo..."
  cd "$SERVER_DIR"
  nohup bash run_local.sh > "$LOGS_DIR/l2server.log" 2>&1 &
  L2_PID=$!
elif [ -n "$SERVER_BINARY" ] && [ -f "$SERVER_BINARY" ]; then
  L2_CMD="$SERVER_BINARY"
  if [ -n "$LOCAL_CHAIN_CONFIG" ]; then
    L2_CMD="$L2_CMD --config $LOCAL_CHAIN_CONFIG"
  fi
  # shellcheck disable=SC2086
  nohup $L2_CMD > "$LOGS_DIR/l2server.log" 2>&1 &
  L2_PID=$!
else
  log "ERROR: cannot locate zksync-os-server binary or run_local.sh"
  log "Run scripts/build_server.sh first"
  exit 1
fi

echo "$L2_PID" > "$PIDS_DIR/l2server.pid"
log "L2 server PID: $L2_PID"

# ── Wait for both RPCs ────────────────────────────────────────────────────────
wait_for_rpc "$L1_RPC" "Anvil (L1)"
wait_for_rpc "$L2_RPC" "zksync-os-server (L2)"

log ""
log "=== Lab is running ==="
log "L1 RPC: $L1_RPC"
log "L2 RPC: $L2_RPC"
log "Logs:   $LOGS_DIR/"
log ""
log "Next: run scripts/discover_addresses.sh"
