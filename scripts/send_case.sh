#!/usr/bin/env bash
# send_case.sh — send a real L1 deposit transaction for a case
#
# Usage:
#   send_case.sh <case_id> <l2GasLimit>
#
# Reads the payload from results/raw/payload_<case_id>.json
# Returns the L1 tx hash and writes it to results/raw/send_<case_id>_<run>.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_ID="${1:?Usage: $0 <case_id> <l2GasLimit>}"
L2_GAS_LIMIT="${2:?Usage: $0 <case_id> <l2GasLimit>}"
RUN_ID="${3:-$(date +%s)}"

L1_RPC="${L1_RPC:-http://localhost:8545}"
DISCOVERY="$ROOT/results/raw/discovery.json"
CASE_FILE="$ROOT/cases/$CASE_ID.json"
PAYLOAD_FILE="$ROOT/results/raw/payload_${CASE_ID}.json"
OUT="$ROOT/results/raw/send_${CASE_ID}_${RUN_ID}.json"
mkdir -p "$(dirname "$OUT")"

log() { echo "[send_case:$CASE_ID] $*"; }
die() { echo "[send_case:$CASE_ID] ERROR: $*" >&2; exit 1; }

[ -f "$DISCOVERY" ] || die "discovery.json missing"
[ -f "$CASE_FILE" ] || die "case file missing: $CASE_FILE"

# ── (Re)build payload at the given gas limit ──────────────────────────────────
log "Building payload for l2GasLimit=$L2_GAS_LIMIT..."
"$ROOT/scripts/build_case_payload.sh" "$CASE_ID" "$L2_GAS_LIMIT" > /dev/null

[ -f "$PAYLOAD_FILE" ] || die "payload file not found after build"

CALLDATA=$(jq -r '.calldata' "$PAYLOAD_FILE")
BRIDGEHUB=$(jq -r '.bridgehub' "$PAYLOAD_FILE")
SENDER=$(jq -r '.sender' "$PAYLOAD_FILE")
MSG_VALUE=$(jq -r '.msgValue' "$PAYLOAD_FILE")
BASE_COST=$(jq -r '.baseCost' "$PAYLOAD_FILE")
MINT_VALUE=$(jq -r '.mintValue' "$PAYLOAD_FILE")
ROUTE=$(jq -r '.route' "$PAYLOAD_FILE")
TOKEN_ADDRESS=$(jq -r '.token_address // "null"' "$CASE_FILE" 2>/dev/null || echo "null")

MSG_VALUE_HEX="0x$(printf '%x' "$MSG_VALUE")"

log "Route: $ROUTE"
log "Sender: $SENDER"
log "Bridgehub: $BRIDGEHUB"
log "msgValue: $MSG_VALUE ($MSG_VALUE_HEX)"
log "mintValue: $MINT_VALUE"
log "baseCost: $BASE_COST"

# ── Handle token approvals if needed ─────────────────────────────────────────
ASSET_ROUTER_L1=$(jq -r '.asset_router_l1' "$DISCOVERY")
NATIVE_TOKEN_VAULT_L1=$(jq -r '.native_token_vault_l1' "$DISCOVERY")

if [[ "$ROUTE" == erc20-base ]] && [ "$TOKEN_ADDRESS" != "null" ]; then
  DEPOSIT_AMOUNT=$(jq -r '.deposit_amount' "$CASE_FILE")
  log "Approving ERC20 token for erc20-base route..."
  log "Token: $TOKEN_ADDRESS | Spender: $NATIVE_TOKEN_VAULT_L1 | Amount: $DEPOSIT_AMOUNT"
  APPROVE_CALLDATA=$(cast calldata "approve(address,uint256)" "$NATIVE_TOKEN_VAULT_L1" "$DEPOSIT_AMOUNT")
  cast send \
    --rpc-url "$L1_RPC" \
    --from "$SENDER" \
    --unlocked \
    "$TOKEN_ADDRESS" \
    "$APPROVE_CALLDATA" \
    --json 2>/dev/null | jq -r '.transactionHash' | xargs -I{} log "Approval tx: {}"
fi

if [[ "$ROUTE" == erc20-nonbase* ]] && [ "$TOKEN_ADDRESS" != "null" ]; then
  DEPOSIT_AMOUNT=$(jq -r '.deposit_amount' "$CASE_FILE")
  log "Approving ERC20 token for erc20-nonbase route..."
  log "Token: $TOKEN_ADDRESS | Spender: $ASSET_ROUTER_L1 | Amount: $DEPOSIT_AMOUNT"
  APPROVE_CALLDATA=$(cast calldata "approve(address,uint256)" "$ASSET_ROUTER_L1" "$DEPOSIT_AMOUNT")
  cast send \
    --rpc-url "$L1_RPC" \
    --from "$SENDER" \
    --unlocked \
    "$TOKEN_ADDRESS" \
    "$APPROVE_CALLDATA" \
    --json 2>/dev/null | jq -r '.transactionHash' | xargs -I{} log "Approval tx: {}"
fi

# ── One final dry-run before sending ─────────────────────────────────────────
log "Final dry-run before real send..."
DRY_RESULT=$(curl -sf -X POST "$L1_RPC" \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{
    \"from\":\"$SENDER\",
    \"to\":\"$BRIDGEHUB\",
    \"data\":\"$CALLDATA\",
    \"value\":\"$MSG_VALUE_HEX\",
    \"gas\":\"0x$(printf '%x' 5000000)\"
  },\"latest\"],\"id\":1}" 2>/dev/null)

DRY_ERROR=$(echo "$DRY_RESULT" | jq -r '.error // null')
if [ "$DRY_ERROR" != "null" ]; then
  die "Dry-run failed before real send: $(echo "$DRY_RESULT" | jq -r '.error.message // .error')"
fi
log "Dry-run passed."

# ── Send real transaction ─────────────────────────────────────────────────────
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log "Sending real transaction at $TIMESTAMP..."

TX_RESULT=$(cast send \
  --rpc-url "$L1_RPC" \
  --from "$SENDER" \
  --unlocked \
  --value "$MSG_VALUE_HEX" \
  --gas-limit "$(printf '%d' 0x$(printf '%x' 5000000))" \
  "$BRIDGEHUB" \
  "$CALLDATA" \
  --json 2>&1) || die "cast send failed: $TX_RESULT"

L1_TX_HASH=$(echo "$TX_RESULT" | jq -r '.transactionHash')
L1_GAS_USED=$(echo "$TX_RESULT" | jq -r '.gasUsed' | xargs printf '%d')
L1_EFFECTIVE_GAS_PRICE=$(echo "$TX_RESULT" | jq -r '.effectiveGasPrice // "0x1"' | xargs printf '%d')
L1_STATUS=$(echo "$TX_RESULT" | jq -r '.status')

log "L1 tx hash: $L1_TX_HASH"
log "L1 gas used: $L1_GAS_USED"
log "L1 status: $L1_STATUS"

if [ "$L1_STATUS" != "0x1" ] && [ "$L1_STATUS" != "1" ]; then
  die "L1 transaction reverted! Hash: $L1_TX_HASH"
fi

# ── Write send result ─────────────────────────────────────────────────────────
jq -n \
  --arg case_id "$CASE_ID" \
  --arg run_id "$RUN_ID" \
  --arg timestamp "$TIMESTAMP" \
  --arg route "$ROUTE" \
  --arg l1_tx_hash "$L1_TX_HASH" \
  --argjson l1_gas_used "$L1_GAS_USED" \
  --argjson l1_effective_gas_price "$L1_EFFECTIVE_GAS_PRICE" \
  --argjson l2_gas_limit "$L2_GAS_LIMIT" \
  --argjson base_cost "$BASE_COST" \
  --argjson mint_value "$MINT_VALUE" \
  --argjson msg_value "$MSG_VALUE" \
  '{
    case_id: $case_id,
    run_id: $run_id,
    timestamp: $timestamp,
    route: $route,
    l2GasLimit: $l2_gas_limit,
    baseCost: $base_cost,
    mintValue: $mint_value,
    msgValue: $msg_value,
    l1_tx_hash: $l1_tx_hash,
    l1_gas_used: $l1_gas_used,
    l1_effective_gas_price: $l1_effective_gas_price
  }' > "$OUT"

echo "$L1_TX_HASH"
log "Send result written to: $OUT"
