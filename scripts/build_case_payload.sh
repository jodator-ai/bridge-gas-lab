#!/usr/bin/env bash
# build_case_payload.sh — construct ABI-encoded calldata for a deposit route
#
# Usage:
#   build_case_payload.sh <case_id> <l2GasLimit>
#
# Reads discovery.json and cases/<case_id>.json
# Outputs a JSON payload file: results/raw/payload_<case_id>.json
#
# Routes:
#   eth-base         → requestL2TransactionDirect
#   erc20-base       → requestL2TransactionDirect (with ERC20 approval)
#   eth-nonbase      → requestL2TransactionTwoBridges
#   erc20-nonbase-*  → requestL2TransactionTwoBridges (with ERC20 approval)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_ID="${1:?Usage: $0 <case_id> <l2GasLimit>}"
L2_GAS_LIMIT="${2:?Usage: $0 <case_id> <l2GasLimit>}"

L1_RPC="${L1_RPC:-http://localhost:8545}"
L2_RPC="${L2_RPC:-http://localhost:3050}"

DISCOVERY="$ROOT/results/raw/discovery.json"
CASE_FILE="$ROOT/cases/$CASE_ID.json"
OUT="$ROOT/results/raw/payload_${CASE_ID}.json"
mkdir -p "$(dirname "$OUT")"

log() { echo "[build_payload] $*"; }
die() { echo "[build_payload] ERROR: $*" >&2; exit 1; }

[ -f "$DISCOVERY" ] || die "discovery.json not found — run discover_addresses.sh"
[ -f "$CASE_FILE" ] || die "case file not found: $CASE_FILE"

# ── Load inputs ───────────────────────────────────────────────────────────────
BRIDGEHUB=$(jq -r '.bridgehub' "$DISCOVERY")
L2_CHAIN_ID=$(jq -r '.l2_chain_id' "$DISCOVERY")
ASSET_ROUTER_L1=$(jq -r '.asset_router_l1' "$DISCOVERY")
RICH=$(jq -r '.rich_account' "$DISCOVERY")

ROUTE=$(jq -r '.route' "$CASE_FILE")
DEPOSIT_AMOUNT=$(jq -r '.deposit_amount' "$CASE_FILE")
RECIPIENT=$(jq -r '.recipient' "$CASE_FILE")
GAS_PER_PUBDATA="${GAS_PER_PUBDATA:-800}"
OPERATOR_TIP="${OPERATOR_TIP:-0}"
FIXED_L1_GAS_PRICE="${FIXED_L1_GAS_PRICE:-1000000000}"  # 1 gwei

TOKEN_ADDRESS=$(jq -r '.token_address // "null"' "$CASE_FILE")

log "Case: $CASE_ID | Route: $ROUTE | Amount: $DEPOSIT_AMOUNT | L2GasLimit: $L2_GAS_LIMIT"

# ── Base cost calculation ─────────────────────────────────────────────────────
# l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, gasPerPubdata) → uint256
# Function selector: 0xb473318e
BASE_COST_DATA="0xb473318e\
$(printf '%064x' "$L2_CHAIN_ID")\
$(printf '%064x' "$FIXED_L1_GAS_PRICE")\
$(printf '%064x' "$L2_GAS_LIMIT")\
$(printf '%064x' "$GAS_PER_PUBDATA")"

BASE_COST_RAW=$(curl -sf -X POST "$L1_RPC" \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$BRIDGEHUB\",\"data\":\"$BASE_COST_DATA\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')

BASE_COST=$(printf '%d' "$BASE_COST_RAW")
log "baseCost: $BASE_COST wei"

# ── Compute mintValue and msgValue per route ──────────────────────────────────
case "$ROUTE" in
  eth-base)
    # mintValue = baseCost + operatorTip + l2Value
    L2_VALUE="$DEPOSIT_AMOUNT"
    MINT_VALUE=$(( BASE_COST + OPERATOR_TIP + L2_VALUE ))
    MSG_VALUE="$MINT_VALUE"
    log "eth-base: mintValue=$MINT_VALUE msgValue=$MSG_VALUE l2Value=$L2_VALUE"
    ;;
  erc20-base)
    # mintValue = baseCost + operatorTip + depositAmount (token covers value)
    MINT_VALUE=$(( BASE_COST + OPERATOR_TIP + DEPOSIT_AMOUNT ))
    MSG_VALUE=0
    L2_VALUE="$DEPOSIT_AMOUNT"
    log "erc20-base: mintValue=$MINT_VALUE msgValue=$MSG_VALUE"
    ;;
  eth-nonbase)
    # mintValue = baseCost + operatorTip (ETH is the deposit, not the base token)
    MINT_VALUE=$(( BASE_COST + OPERATOR_TIP ))
    MSG_VALUE="$DEPOSIT_AMOUNT"
    L2_VALUE="$DEPOSIT_AMOUNT"
    log "eth-nonbase: mintValue=$MINT_VALUE msgValue=$MSG_VALUE depositAmount=$DEPOSIT_AMOUNT"
    ;;
  erc20-nonbase*)
    # mintValue = baseCost + operatorTip
    MINT_VALUE=$(( BASE_COST + OPERATOR_TIP ))
    # If base token is ETH, msg.value = 0 (fees covered by base token approval)
    # This depends on chain config — default to 0 for ERC20 base token chains
    MSG_VALUE=0
    L2_VALUE=0
    log "erc20-nonbase: mintValue=$MINT_VALUE msgValue=$MSG_VALUE"
    ;;
  *)
    die "Unknown route: $ROUTE"
    ;;
esac

# ── Encode calldata ───────────────────────────────────────────────────────────
# ZKsync transaction request struct encoding via cast abi-encode

REFUND_RECIPIENT="$RICH"
L2_GAS_LIMIT_HEX="0x$(printf '%x' "$L2_GAS_LIMIT")"
GAS_PER_PUBDATA_HEX="0x$(printf '%x' "$GAS_PER_PUBDATA")"
MINT_VALUE_HEX="0x$(printf '%x' "$MINT_VALUE")"
MSG_VALUE_HEX="0x$(printf '%x' "$MSG_VALUE")"
L2_VALUE_HEX="0x$(printf '%x' "$L2_VALUE")"
OPERATOR_TIP_HEX="0x$(printf '%x' "$OPERATOR_TIP")"

case "$ROUTE" in
  eth-base|erc20-base)
    # requestL2TransactionDirect(L2TransactionRequestDirect)
    # struct L2TransactionRequestDirect {
    #   uint256 chainId; address mintToken; uint256 mintValue; address l2Contract;
    #   uint256 l2Value; bytes l2Calldata; uint256 l2GasLimit; uint256 l2GasPerPubdataByteLimit;
    #   bytes[] factoryDeps; address refundRecipient;
    # }
    CALLDATA=$(cast abi-encode \
      "f((uint256,address,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))" \
      "($L2_CHAIN_ID,0x0000000000000000000000000000000000000000,$MINT_VALUE_HEX,$RECIPIENT,$L2_VALUE_HEX,0x,$L2_GAS_LIMIT_HEX,$GAS_PER_PUBDATA_HEX,[],${REFUND_RECIPIENT})" \
      2>/dev/null || echo "ENCODE_FAILED")
    # Prepend function selector for requestL2TransactionDirect(L2TransactionRequestDirect)
    SELECTOR="0xca40b51b"
    FULL_CALLDATA="${SELECTOR}${CALLDATA#0x}"
    ;;

  eth-nonbase|erc20-nonbase*)
    # requestL2TransactionTwoBridges(L2TransactionRequestTwoBridgesOuter)
    # struct L2TransactionRequestTwoBridgesOuter {
    #   uint256 chainId; uint256 mintValue; uint256 l2Value; uint256 l2GasLimit;
    #   uint256 l2GasPerPubdataByteLimit; address refundRecipient; address secondBridgeAddress;
    #   uint256 secondBridgeValue; bytes secondBridgeCalldata;
    # }
    SECOND_BRIDGE="$ASSET_ROUTER_L1"
    # secondBridgeCalldata encodes the asset transfer details
    SECOND_CALLDATA=$(cast abi-encode \
      "f(address,uint256,address)" \
      "($TOKEN_ADDRESS,$DEPOSIT_AMOUNT,$RECIPIENT)" \
      2>/dev/null || echo "ENCODE_FAILED")
    CALLDATA=$(cast abi-encode \
      "f((uint256,uint256,uint256,uint256,uint256,address,address,uint256,bytes))" \
      "($L2_CHAIN_ID,$MINT_VALUE_HEX,$L2_VALUE_HEX,$L2_GAS_LIMIT_HEX,$GAS_PER_PUBDATA_HEX,$REFUND_RECIPIENT,$SECOND_BRIDGE,$MSG_VALUE_HEX,$SECOND_CALLDATA)" \
      2>/dev/null || echo "ENCODE_FAILED")
    SELECTOR="0x22b2dcff"
    FULL_CALLDATA="${SELECTOR}${CALLDATA#0x}"
    ;;
esac

# ── Write payload JSON ────────────────────────────────────────────────────────
jq -n \
  --arg case_id "$CASE_ID" \
  --arg route "$ROUTE" \
  --arg bridgehub "$BRIDGEHUB" \
  --argjson l2_chain_id "$L2_CHAIN_ID" \
  --argjson l2_gas_limit "$L2_GAS_LIMIT" \
  --argjson gas_per_pubdata "$GAS_PER_PUBDATA" \
  --argjson operator_tip "$OPERATOR_TIP" \
  --argjson base_cost "$BASE_COST" \
  --argjson mint_value "$MINT_VALUE" \
  --argjson msg_value "$MSG_VALUE" \
  --argjson deposit_amount "$DEPOSIT_AMOUNT" \
  --arg fixed_l1_gas_price "$FIXED_L1_GAS_PRICE" \
  --arg sender "$RICH" \
  --arg recipient "$RECIPIENT" \
  --arg calldata "$FULL_CALLDATA" \
  '{
    case_id: $case_id,
    route: $route,
    bridgehub: $bridgehub,
    l2_chain_id: $l2_chain_id,
    l2GasLimit: $l2_gas_limit,
    gasPerPubdata: $gas_per_pubdata,
    operatorTip: $operator_tip,
    baseCost: $base_cost,
    mintValue: $mint_value,
    msgValue: $msg_value,
    depositAmount: $deposit_amount,
    fixedL1GasPrice: $fixed_l1_gas_price,
    sender: $sender,
    recipient: $recipient,
    calldata: $calldata
  }' > "$OUT"

log "Payload written to: $OUT"
cat "$OUT"
