#!/usr/bin/env bash
# run_case.sh — run one full case: find min gas, send, collect receipts
#
# Usage:
#   run_case.sh <case_id> [run_number]
#
# Performs:
#   1. Reset lab
#   2. Discover addresses
#   3. Find minimum passing l2GasLimit
#   4. Send real L1 transaction
#   5. Find L2 receipt
#   6. Write raw result JSON
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_ID="${1:?Usage: $0 <case_id> [run_number]}"
RUN_NUM="${2:-1}"

DISCOVERY="$ROOT/results/raw/discovery.json"
CASE_FILE="$ROOT/cases/$CASE_ID.json"
OUT="$ROOT/results/raw/${CASE_ID}_run${RUN_NUM}.json"
mkdir -p "$(dirname "$OUT")"

log() { echo "[run_case:$CASE_ID:run$RUN_NUM] $*"; }
die() { echo "[run_case:$CASE_ID:run$RUN_NUM] ERROR: $*" >&2; exit 1; }

[ -f "$CASE_FILE" ] || die "case file missing: $CASE_FILE"

log "=== Starting case run ==="
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ── Load case metadata ────────────────────────────────────────────────────────
ROUTE=$(jq -r '.route' "$CASE_FILE")
DEPOSIT_AMOUNT=$(jq -r '.deposit_amount' "$CASE_FILE")
RECIPIENT_KIND=$(jq -r '.recipient_kind' "$CASE_FILE")
TOKEN_MODE=$(jq -r '.token_mode // "na"' "$CASE_FILE")
GAS_PER_PUBDATA="${GAS_PER_PUBDATA:-800}"
OPERATOR_TIP="${OPERATOR_TIP:-0}"
FIXED_L1_GAS_PRICE="${FIXED_L1_GAS_PRICE:-1000000000}"

log "Route: $ROUTE | Deposit: $DEPOSIT_AMOUNT | Recipient: $RECIPIENT_KIND"

# ── Step 1: Reset lab ─────────────────────────────────────────────────────────
log "Resetting lab..."
"$ROOT/scripts/reset_lab.sh" 2>&1 | grep -E '^\[' || true

# ── Step 2: Sanity check ──────────────────────────────────────────────────────
log "Running sanity checks..."
"$ROOT/scripts/sanity_check.sh" || die "Sanity checks failed — aborting run"

# ── Step 3 (erc20-nonbase-existing only): preparatory deposit ─────────────────
if [[ "$ROUTE" == erc20-nonbase* ]] && [ "$TOKEN_MODE" = "existing" ]; then
  log "Token mode=existing: running preparatory deposit..."
  PREP_CASE="${CASE_ID%-existing}-first"
  if [ -f "$ROOT/cases/${PREP_CASE}.json" ]; then
    # Run a single prep deposit (not counted in results)
    "$ROOT/scripts/build_case_payload.sh" "$PREP_CASE" 2000000 > /dev/null
    PREP_PAYLOAD="$ROOT/results/raw/payload_${PREP_CASE}.json"
    CALLDATA=$(jq -r '.calldata' "$PREP_PAYLOAD")
    BRIDGEHUB=$(jq -r '.bridgehub' "$PREP_PAYLOAD")
    SENDER=$(jq -r '.sender' "$PREP_PAYLOAD")
    MSG_VALUE=$(jq -r '.msgValue' "$PREP_PAYLOAD")
    cast send --rpc-url "${L1_RPC:-http://localhost:8545}" \
      --from "$SENDER" --unlocked \
      --value "0x$(printf '%x' "$MSG_VALUE")" \
      "$BRIDGEHUB" "$CALLDATA" --json > /dev/null 2>&1
    log "Preparatory deposit sent — waiting 10s for L2 processing..."
    sleep 10
  else
    log "WARNING: prep case $PREP_CASE not found — skipping preparatory deposit"
  fi
fi

# ── Step 4: Find minimum l2GasLimit ──────────────────────────────────────────
log "Finding minimum passing l2GasLimit..."
MIN_L2_GAS=$("$ROOT/scripts/find_min_l2_gas.sh" "$CASE_ID") || \
  die "Failed to find minimum l2GasLimit"
log "Minimum l2GasLimit: $MIN_L2_GAS"

# ── Step 5: Send real deposit ─────────────────────────────────────────────────
RUN_ID="${CASE_ID}_run${RUN_NUM}_$(date +%s)"
log "Sending real L1 deposit..."
L1_TX_HASH=$("$ROOT/scripts/send_case.sh" "$CASE_ID" "$MIN_L2_GAS" "$RUN_ID") || \
  die "Failed to send deposit"
log "L1 tx hash: $L1_TX_HASH"

# ── Step 6: Find L2 receipt ───────────────────────────────────────────────────
log "Polling for L2 receipt..."
L2_DATA=$("$ROOT/scripts/find_l2_receipt.sh" "$L1_TX_HASH" 180) || {
  log "WARNING: L2 receipt not found within timeout"
  L2_DATA='{"l2_tx_hash":null,"l2_gas_used":0,"l2_status":"timeout"}'
}
L2_TX_HASH=$(echo "$L2_DATA" | jq -r '.l2_tx_hash // null')
L2_GAS_USED=$(echo "$L2_DATA" | jq -r '.l2_gas_used // 0')
L2_STATUS=$(echo "$L2_DATA" | jq -r '.l2_status // "unknown"')

log "L2 tx hash: $L2_TX_HASH | gasUsed: $L2_GAS_USED | status: $L2_STATUS"

# ── Load send result for L1 measurements ─────────────────────────────────────
SEND_FILE="$ROOT/results/raw/send_${RUN_ID}.json"
if [ -f "$SEND_FILE" ]; then
  L1_GAS_USED=$(jq -r '.l1_gas_used' "$SEND_FILE")
  L1_EFFECTIVE_GAS_PRICE=$(jq -r '.l1_effective_gas_price' "$SEND_FILE")
  BASE_COST=$(jq -r '.baseCost' "$SEND_FILE")
  MINT_VALUE=$(jq -r '.mintValue' "$SEND_FILE")
  MSG_VALUE=$(jq -r '.msgValue' "$SEND_FILE")
else
  L1_GAS_USED=0
  L1_EFFECTIVE_GAS_PRICE=0
  BASE_COST=0
  MINT_VALUE=0
  MSG_VALUE=0
fi

# ── Read discovery values ─────────────────────────────────────────────────────
L2_CHAIN_ID=$(jq -r '.l2_chain_id' "$DISCOVERY")
BASE_TOKEN_KIND=$(jq -r '.base_token_kind' "$DISCOVERY")

# ── Determine protocol version ────────────────────────────────────────────────
PROTOCOL_VERSION=$(curl -sf -X POST "${L2_RPC:-http://localhost:3050}" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"zks_getProtocolVersion","params":[],"id":1}' \
  | jq -r '.result // "unknown"' 2>/dev/null || echo "unknown")

# ── Write raw result ──────────────────────────────────────────────────────────
NOTES=""
if [ "$L2_STATUS" = "timeout" ]; then
  NOTES="L2 receipt not found within timeout"
fi
if [ "$L2_STATUS" != "0x1" ] && [ "$L2_STATUS" != "1" ] && [ "$L2_STATUS" != "timeout" ]; then
  NOTES="L2 transaction reverted: $L2_STATUS"
fi

jq -n \
  --arg case_id "$CASE_ID" \
  --arg run_id "$RUN_NUM" \
  --arg timestamp "$TIMESTAMP" \
  --arg protocol_version "$PROTOCOL_VERSION" \
  --argjson chain_id "$L2_CHAIN_ID" \
  --arg base_token_kind "$BASE_TOKEN_KIND" \
  --arg route "$ROUTE" \
  --arg token_mode "$TOKEN_MODE" \
  --arg recipient_kind "$RECIPIENT_KIND" \
  --argjson deposit_amount "$DEPOSIT_AMOUNT" \
  --argjson gas_per_pubdata "$GAS_PER_PUBDATA" \
  --argjson operator_tip "$OPERATOR_TIP" \
  --arg fixed_l1_gas_price "$FIXED_L1_GAS_PRICE" \
  --argjson min_passing_l2_gas_limit "$MIN_L2_GAS" \
  --argjson base_cost "$BASE_COST" \
  --argjson mint_value "$MINT_VALUE" \
  --argjson msg_value "$MSG_VALUE" \
  --arg l1_tx_hash "$L1_TX_HASH" \
  --argjson l1_gas_used "$L1_GAS_USED" \
  --argjson l1_effective_gas_price "$L1_EFFECTIVE_GAS_PRICE" \
  --argjson l2_tx_hash "$L2_TX_HASH" \
  --argjson l2_gas_used "$L2_GAS_USED" \
  --arg l2_status "$L2_STATUS" \
  --arg notes "$NOTES" \
  '{
    case_id: $case_id,
    run_id: ($run_id | tonumber),
    timestamp: $timestamp,
    protocol_version: $protocol_version,
    chain_id: $chain_id,
    base_token_kind: $base_token_kind,
    route: $route,
    token_mode: $token_mode,
    recipient_kind: $recipient_kind,
    deposit_amount: $deposit_amount,
    gasPerPubdata: $gas_per_pubdata,
    operatorTip: $operator_tip,
    fixedL1GasPrice: $fixed_l1_gas_price,
    min_passing_l2GasLimit: $min_passing_l2_gas_limit,
    baseCost: $base_cost,
    mintValue: $mint_value,
    msgValue: $msg_value,
    l1_tx_hash: $l1_tx_hash,
    l1_gas_used: $l1_gas_used,
    l1_effective_gas_price: $l1_effective_gas_price,
    l2_tx_hash: $l2_tx_hash,
    l2_gas_used: $l2_gas_used,
    l2_status: $l2_status,
    notes: $notes
  }' > "$OUT"

log "Raw result written to: $OUT"
log "=== Case run complete ==="
