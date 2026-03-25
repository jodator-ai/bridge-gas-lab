#!/usr/bin/env bash
# deploy_contracts.sh — compile and deploy lab contracts to L1 and L2
#
# Deploys:
#   L1: TestERC20 (for ERC20 route testing)
#   L2: PayableReceiver (for eth-base-contract test case)
#
# Outputs addresses to results/raw/contracts.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L1_RPC="${L1_RPC:-http://localhost:8545}"
L2_RPC="${L2_RPC:-http://localhost:3050}"
DISCOVERY="$ROOT/results/raw/discovery.json"
OUT="$ROOT/results/raw/contracts.json"
mkdir -p "$(dirname "$OUT")"

log() { echo "[deploy_contracts] $*"; }
die() { echo "[deploy_contracts] ERROR: $*" >&2; exit 1; }

[ -f "$DISCOVERY" ] || die "discovery.json missing — run discover_addresses.sh first"

RICH=$(jq -r '.rich_account' "$DISCOVERY")
CONTRACTS_DIR="$ROOT/contracts"

log "Deployer: $RICH"
log "Contracts dir: $CONTRACTS_DIR"

# ── Compile contracts ─────────────────────────────────────────────────────────
log "Compiling contracts..."
cd "$ROOT"

# Use forge if available
if command -v forge &>/dev/null; then
  forge build --contracts "$CONTRACTS_DIR" --out "$ROOT/.build/out" --cache-path "$ROOT/.build/cache" 2>&1 | tail -5
  USING_FORGE=true
else
  log "forge not found — using cast with inline bytecode"
  USING_FORGE=false
fi

# ── Deploy TestERC20 on L1 ────────────────────────────────────────────────────
log "Deploying TestERC20 on L1..."

if $USING_FORGE; then
  BYTECODE=$(cat "$ROOT/.build/out/TestERC20.sol/TestERC20.json" | jq -r '.bytecode.object')
  # Encode constructor args: name="LabToken", symbol="LAB", decimals=18
  CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(string,string,uint8)" "LabToken" "LAB" 18)
  DEPLOY_DATA="${BYTECODE}${CONSTRUCTOR_ARGS#0x}"
else
  # Inline bytecode via cast (solc compile)
  ERC20_SOURCE="$CONTRACTS_DIR/TestERC20.sol"
  DEPLOY_DATA=$(solc --bin --abi --optimize "$ERC20_SOURCE" 2>/dev/null | \
    grep -A1 "Binary:" | tail -1 || echo "")
  if [ -z "$DEPLOY_DATA" ]; then
    die "Could not compile TestERC20.sol — install forge or solc"
  fi
fi

ERC20_DEPLOY_RESULT=$(cast send \
  --rpc-url "$L1_RPC" \
  --from "$RICH" \
  --unlocked \
  --create "$DEPLOY_DATA" \
  --json 2>/dev/null) || die "Failed to deploy TestERC20"

ERC20_ADDRESS=$(echo "$ERC20_DEPLOY_RESULT" | jq -r '.contractAddress')
log "TestERC20 deployed at: $ERC20_ADDRESS"

# ── Mint tokens to rich account ───────────────────────────────────────────────
MINT_AMOUNT="100000000000000000000000"  # 100,000 tokens
log "Minting $MINT_AMOUNT to $RICH..."
MINT_CALLDATA=$(cast calldata "mint(address,uint256)" "$RICH" "$MINT_AMOUNT")
cast send \
  --rpc-url "$L1_RPC" \
  --from "$RICH" \
  --unlocked \
  "$ERC20_ADDRESS" \
  "$MINT_CALLDATA" \
  --json > /dev/null
log "Minted successfully"

# Verify balance
BALANCE_DATA=$(cast call --rpc-url "$L1_RPC" "$ERC20_ADDRESS" "balanceOf(address)(uint256)" "$RICH")
log "Rich account TestERC20 balance: $BALANCE_DATA"

# ── Deploy PayableReceiver on L2 ──────────────────────────────────────────────
log "Deploying PayableReceiver on L2..."

if $USING_FORGE; then
  PAYABLE_BYTECODE=$(cat "$ROOT/.build/out/PayableReceiver.sol/PayableReceiver.json" | jq -r '.bytecode.object')
else
  PAYABLE_SOURCE="$CONTRACTS_DIR/PayableReceiver.sol"
  PAYABLE_BYTECODE=$(solc --bin --optimize "$PAYABLE_SOURCE" 2>/dev/null | \
    grep -A1 "Binary:" | tail -1 || echo "")
fi

if [ -n "$PAYABLE_BYTECODE" ] && [ "$PAYABLE_BYTECODE" != "null" ]; then
  PAYABLE_RESULT=$(cast send \
    --rpc-url "$L2_RPC" \
    --from "$RICH" \
    --unlocked \
    --create "$PAYABLE_BYTECODE" \
    --json 2>/dev/null) || { log "WARNING: PayableReceiver deploy failed (L2 may not support this deployment method)"; PAYABLE_ADDRESS="null"; }

  if [ "${PAYABLE_RESULT:-}" != "" ]; then
    PAYABLE_ADDRESS=$(echo "$PAYABLE_RESULT" | jq -r '.contractAddress // null')
  else
    PAYABLE_ADDRESS="null"
  fi
else
  log "WARNING: Could not get PayableReceiver bytecode — eth-base-contract case skipped"
  PAYABLE_ADDRESS="null"
fi

log "PayableReceiver deployed at: $PAYABLE_ADDRESS"

# ── Update case files with real addresses ─────────────────────────────────────
log "Updating case files with deployed addresses..."

for CASE_FILE in "$ROOT/cases"/*.json; do
  CASE_ID=$(basename "$CASE_FILE" .json)
  TOKEN_ADDR=$(jq -r '.token_address // ""' "$CASE_FILE")
  RECIPIENT=$(jq -r '.recipient // ""' "$CASE_FILE")

  UPDATED=false

  if [ "$TOKEN_ADDR" = "DEPLOY_TEST_ERC20" ]; then
    jq --arg addr "$ERC20_ADDRESS" '.token_address = $addr' "$CASE_FILE" > "${CASE_FILE}.tmp"
    mv "${CASE_FILE}.tmp" "$CASE_FILE"
    log "  Updated $CASE_ID token_address: $ERC20_ADDRESS"
    UPDATED=true
  fi

  if [ "$RECIPIENT" = "DEPLOY_PAYABLE_CONTRACT" ] && [ "$PAYABLE_ADDRESS" != "null" ]; then
    jq --arg addr "$PAYABLE_ADDRESS" '.recipient = $addr' "$CASE_FILE" > "${CASE_FILE}.tmp"
    mv "${CASE_FILE}.tmp" "$CASE_FILE"
    log "  Updated $CASE_ID recipient: $PAYABLE_ADDRESS"
    UPDATED=true
  fi
done

# ── Write contracts.json ──────────────────────────────────────────────────────
jq -n \
  --arg erc20 "$ERC20_ADDRESS" \
  --arg payable "${PAYABLE_ADDRESS:-null}" \
  --arg rich "$RICH" \
  --arg mint_amount "$MINT_AMOUNT" \
  '{
    test_erc20_l1: $erc20,
    payable_receiver_l2: $payable,
    rich_account: $rich,
    erc20_minted_amount: $mint_amount
  }' > "$OUT"

log ""
log "=== Contract deployment complete ==="
cat "$OUT"
