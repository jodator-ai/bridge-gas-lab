#!/usr/bin/env bash
# reset_lab.sh — full reset of both L1 and L2 to clean known state
# Usage: reset_lab.sh [--soft]
#   default: full restart (stop + start)
#   --soft:  anvil snapshot reset only (faster, keeps L2 running)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L1_RPC="http://localhost:8545"

log() { echo "[reset_lab] $*"; }

SOFT=false
if [ "${1:-}" = "--soft" ]; then
  SOFT=true
fi

if $SOFT; then
  log "Soft reset: resetting Anvil state only..."
  # anvil_reset resets to the genesis/loaded state
  RESULT=$(curl -sf -X POST "$L1_RPC" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"anvil_reset","params":[],"id":1}')
  log "anvil_reset response: $RESULT"
  log "Soft reset complete (L2 server not restarted)"
else
  log "Full reset: stopping and restarting lab..."
  "$ROOT/scripts/stop_lab.sh"
  sleep 2
  "$ROOT/scripts/start_lab.sh"
  log "Full reset complete"
fi

log "Re-running discovery after reset..."
"$ROOT/scripts/discover_addresses.sh"
