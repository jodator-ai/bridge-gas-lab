#!/usr/bin/env bash
# find_l2_receipt.sh — poll L2 for the priority transaction corresponding to an L1 deposit
#
# Usage:
#   find_l2_receipt.sh <l1_tx_hash> [timeout_seconds]
#
# Strategy: after an L1 deposit, the next new priority transaction on L2
#           is the corresponding deposit. Poll L2 blocks until found.
#
# Outputs: JSON receipt on stdout
set -euo pipefail

L1_TX_HASH="${1:?Usage: $0 <l1_tx_hash> [timeout_seconds]}"
TIMEOUT="${2:-120}"
L2_RPC="${L2_RPC:-http://localhost:3050}"
L1_RPC="${L1_RPC:-http://localhost:8545}"

log() { echo "[find_l2_receipt] $*" >&2; }

rpc_call() {
  local rpc="$1" method="$2" params="${3:-[]}"
  curl -sf --max-time 10 -X POST "$rpc" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}"
}

# ── Get L1 tx block number for correlation ────────────────────────────────────
L1_RECEIPT=$(rpc_call "$L1_RPC" "eth_getTransactionReceipt" "[\"$L1_TX_HASH\"]")
L1_BLOCK=$(echo "$L1_RECEIPT" | jq -r '.result.blockNumber // "null"')

if [ "$L1_BLOCK" = "null" ]; then
  log "WARNING: L1 receipt not found for $L1_TX_HASH — tx may not be mined yet"
fi

log "L1 deposit tx: $L1_TX_HASH (block $L1_BLOCK)"
log "Polling L2 RPC for priority tx receipt (timeout: ${TIMEOUT}s)..."

# ── Get current L2 block as baseline ─────────────────────────────────────────
BASELINE_BLOCK_HEX=$(rpc_call "$L2_RPC" "eth_blockNumber" | jq -r '.result')
BASELINE_BLOCK=$(printf '%d' "$BASELINE_BLOCK_HEX")
log "L2 baseline block: $BASELINE_BLOCK"

# ── Poll for new L2 blocks with priority txs ─────────────────────────────────
START_TIME=$(date +%s)
LAST_CHECKED=$BASELINE_BLOCK

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_TIME ))
  if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
    log "TIMEOUT: No L2 receipt found after ${TIMEOUT}s for $L1_TX_HASH"
    echo "{\"error\":\"timeout\",\"l1_tx_hash\":\"$L1_TX_HASH\"}"
    exit 1
  fi

  # Get current L2 block
  CURRENT_BLOCK_HEX=$(rpc_call "$L2_RPC" "eth_blockNumber" | jq -r '.result' 2>/dev/null || echo "$LAST_CHECKED")
  CURRENT_BLOCK=$(printf '%d' "$CURRENT_BLOCK_HEX")

  if [ "$CURRENT_BLOCK" -gt "$LAST_CHECKED" ]; then
    # Check new blocks for priority transactions
    for BN in $(seq $(( LAST_CHECKED + 1 )) "$CURRENT_BLOCK"); do
      BN_HEX="0x$(printf '%x' "$BN")"
      BLOCK=$(rpc_call "$L2_RPC" "eth_getBlockByNumber" "[\"$BN_HEX\",true]" | jq -r '.result')
      if [ "$BLOCK" = "null" ] || [ -z "$BLOCK" ]; then
        continue
      fi

      # Priority transactions have type=0xff (255) or can be identified by zksync metadata
      TX_COUNT=$(echo "$BLOCK" | jq -r '.transactions | length')
      if [ "$TX_COUNT" -eq 0 ]; then
        continue
      fi

      # Check each tx — priority txs have type=255 or source from system
      PRIORITY_TX=$(echo "$BLOCK" | jq -r '
        .transactions[]
        | select(.type == "0xff" or .type == 255 or (.from // "" | ascii_downcase) == "0x0000000000000000000000000000000000008001")
        | .hash
      ' | head -1)

      if [ -n "$PRIORITY_TX" ] && [ "$PRIORITY_TX" != "null" ]; then
        log "Found priority tx candidate: $PRIORITY_TX in L2 block $BN"

        # Get full receipt
        RECEIPT=$(rpc_call "$L2_RPC" "eth_getTransactionReceipt" "[\"$PRIORITY_TX\"]" | jq -r '.result')
        if [ "$RECEIPT" = "null" ] || [ -z "$RECEIPT" ]; then
          log "Receipt not ready yet for $PRIORITY_TX, continuing..."
          continue
        fi

        L2_GAS_USED=$(echo "$RECEIPT" | jq -r '.gasUsed // "0x0"')
        L2_GAS_USED_DEC=$(printf '%d' "$L2_GAS_USED")
        L2_STATUS=$(echo "$RECEIPT" | jq -r '.status')

        log "L2 receipt found:"
        log "  hash:     $PRIORITY_TX"
        log "  gasUsed:  $L2_GAS_USED_DEC"
        log "  status:   $L2_STATUS"

        # Output the result
        jq -n \
          --arg l1_tx_hash "$L1_TX_HASH" \
          --arg l2_tx_hash "$PRIORITY_TX" \
          --argjson l2_gas_used "$L2_GAS_USED_DEC" \
          --arg l2_status "$L2_STATUS" \
          --argjson l2_block "$BN" \
          '{
            l1_tx_hash: $l1_tx_hash,
            l2_tx_hash: $l2_tx_hash,
            l2_gas_used: $l2_gas_used,
            l2_status: $l2_status,
            l2_block: $l2_block
          }'
        exit 0
      fi
    done
    LAST_CHECKED=$CURRENT_BLOCK
  fi

  sleep 2
done
