#!/usr/bin/env bash
# discover_addresses.sh — discover all bridge addresses dynamically
# Output: results/raw/discovery.json
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L1_RPC="${L1_RPC:-http://localhost:8545}"
L2_RPC="${L2_RPC:-http://localhost:3050}"
OUT="$ROOT/results/raw/discovery.json"
mkdir -p "$(dirname "$OUT")"

log() { echo "[discover] $*"; }
die() { echo "[discover] ERROR: $*" >&2; exit 1; }

rpc_call() {
  local rpc="$1"
  local method="$2"
  local params="${3:-[]}"
  curl -sf -X POST "$rpc" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}"
}

eth_call() {
  local rpc="$1"
  local to="$2"
  local data="$3"
  rpc_call "$rpc" "eth_call" "[{\"to\":\"$to\",\"data\":\"$data\"},\"latest\"]"
}

log "=== Address Discovery ==="
log "L1 RPC: $L1_RPC"
log "L2 RPC: $L2_RPC"

# ── L1 chain ID ───────────────────────────────────────────────────────────────
L1_CHAIN_ID_HEX=$(rpc_call "$L1_RPC" "eth_chainId" | jq -r '.result')
L1_CHAIN_ID=$(printf '%d' "$L1_CHAIN_ID_HEX")
log "L1 chainId: $L1_CHAIN_ID"

# ── L2 chain ID ───────────────────────────────────────────────────────────────
L2_CHAIN_ID_HEX=$(rpc_call "$L2_RPC" "eth_chainId" | jq -r '.result')
L2_CHAIN_ID=$(printf '%d' "$L2_CHAIN_ID_HEX")
log "L2 chainId: $L2_CHAIN_ID"

# ── Bridgehub address ─────────────────────────────────────────────────────────
BRIDGEHUB_RESULT=$(rpc_call "$L2_RPC" "zks_getBridgehubContract" | jq -r '.result')
if [ -z "$BRIDGEHUB_RESULT" ] || [ "$BRIDGEHUB_RESULT" = "null" ]; then
  # Try L1 RPC as fallback
  BRIDGEHUB_RESULT=$(rpc_call "$L1_RPC" "zks_getBridgehubContract" | jq -r '.result' 2>/dev/null || echo "null")
fi

if [ -z "$BRIDGEHUB_RESULT" ] || [ "$BRIDGEHUB_RESULT" = "null" ]; then
  die "Could not discover Bridgehub address from either RPC"
fi
BRIDGEHUB="$BRIDGEHUB_RESULT"
log "Bridgehub: $BRIDGEHUB"

# ── Base token on L1 ─────────────────────────────────────────────────────────
# Bridgehub.baseToken(chainId) — selector: 0x45240cbf
BASE_TOKEN_DATA="0x45240cbf$(printf '%064x' "$L2_CHAIN_ID")"
BASE_TOKEN_RAW=$(eth_call "$L1_RPC" "$BRIDGEHUB" "$BASE_TOKEN_DATA" | jq -r '.result')
# Extract address from 32-byte return (last 20 bytes)
BASE_TOKEN="0x${BASE_TOKEN_RAW: -40}"
log "Base token on L1 (for L2 chain $L2_CHAIN_ID): $BASE_TOKEN"

# Determine base token kind
ETH_ADDRESS="0x0000000000000000000000000000000000000001"
if [ "${BASE_TOKEN,,}" = "${ETH_ADDRESS,,}" ] || [ "${BASE_TOKEN}" = "0x$(printf '%040s' | tr ' ' '0')" ]; then
  BASE_TOKEN_KIND="eth"
else
  BASE_TOKEN_KIND="erc20"
fi
log "Base token kind: $BASE_TOKEN_KIND"

# ── Asset Router (L1) ─────────────────────────────────────────────────────────
# Bridgehub.assetRouter() — selector: 0xe8c4c0b8
ASSET_ROUTER_RAW=$(eth_call "$L1_RPC" "$BRIDGEHUB" "0xe8c4c0b8" | jq -r '.result')
ASSET_ROUTER_L1="0x${ASSET_ROUTER_RAW: -40}"
log "Asset Router (L1): $ASSET_ROUTER_L1"

# ── Shared Bridge (L1) ────────────────────────────────────────────────────────
# Try getL1SharedBridge() — selector: 0xf3b9ac3e (may vary by version)
SHARED_BRIDGE_RAW=$(eth_call "$L1_RPC" "$BRIDGEHUB" "0xf3b9ac3e" | jq -r '.result' 2>/dev/null || echo "0x$(printf '%064s' | tr ' ' '0')")
SHARED_BRIDGE_L1="0x${SHARED_BRIDGE_RAW: -40}"
log "Shared Bridge (L1): $SHARED_BRIDGE_L1"

# ── Native Token Vault (L1) ───────────────────────────────────────────────────
# AssetRouter.nativeTokenVault() — selector: 0xc82b8134
NTV_RAW=$(eth_call "$L1_RPC" "$ASSET_ROUTER_L1" "0xc82b8134" | jq -r '.result' 2>/dev/null || echo "0x$(printf '%064s' | tr ' ' '0')")
NATIVE_TOKEN_VAULT_L1="0x${NTV_RAW: -40}"
log "Native Token Vault (L1): $NATIVE_TOKEN_VAULT_L1"

# ── L2 bridge addresses ───────────────────────────────────────────────────────
# zks_getBridgeContracts
L2_BRIDGE_RESULT=$(rpc_call "$L2_RPC" "zks_getBridgeContracts" | jq -r '.result')
L2_SHARED_BRIDGE=$(echo "$L2_BRIDGE_RESULT" | jq -r '.l2SharedDefaultBridge // .l2ERC20DefaultBridge // "null"')
L2_ERC20_BRIDGE=$(echo "$L2_BRIDGE_RESULT" | jq -r '.l2Erc20DefaultBridge // .l2ERC20DefaultBridge // "null"')
log "L2 Shared Bridge: $L2_SHARED_BRIDGE"
log "L2 ERC20 Bridge: $L2_ERC20_BRIDGE"

# ── Rich account (L1) ─────────────────────────────────────────────────────────
# Anvil default rich accounts — first one
RICH_ACCOUNT="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
RICH_BALANCE_HEX=$(rpc_call "$L1_RPC" "eth_getBalance" "[\"$RICH_ACCOUNT\",\"latest\"]" | jq -r '.result')
RICH_BALANCE_WEI=$(printf '%d' "$RICH_BALANCE_HEX")
log "Rich account (L1): $RICH_ACCOUNT balance $RICH_BALANCE_WEI wei"

# ── Write discovery.json ──────────────────────────────────────────────────────
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

jq -n \
  --arg ts "$TIMESTAMP" \
  --argjson l1_chain_id "$L1_CHAIN_ID" \
  --argjson l2_chain_id "$L2_CHAIN_ID" \
  --arg bridgehub "$BRIDGEHUB" \
  --arg base_token "$BASE_TOKEN" \
  --arg base_token_kind "$BASE_TOKEN_KIND" \
  --arg asset_router_l1 "$ASSET_ROUTER_L1" \
  --arg shared_bridge_l1 "$SHARED_BRIDGE_L1" \
  --arg native_token_vault_l1 "$NATIVE_TOKEN_VAULT_L1" \
  --arg l2_shared_bridge "$L2_SHARED_BRIDGE" \
  --arg l2_erc20_bridge "$L2_ERC20_BRIDGE" \
  --arg rich_account "$RICH_ACCOUNT" \
  --arg l1_rpc "$L1_RPC" \
  --arg l2_rpc "$L2_RPC" \
  '{
    timestamp: $ts,
    l1_chain_id: $l1_chain_id,
    l2_chain_id: $l2_chain_id,
    l1_rpc: $l1_rpc,
    l2_rpc: $l2_rpc,
    bridgehub: $bridgehub,
    base_token_l1: $base_token,
    base_token_kind: $base_token_kind,
    asset_router_l1: $asset_router_l1,
    shared_bridge_l1: $shared_bridge_l1,
    native_token_vault_l1: $native_token_vault_l1,
    l2_shared_bridge: $l2_shared_bridge,
    l2_erc20_bridge: $l2_erc20_bridge,
    rich_account: $rich_account
  }' > "$OUT"

log ""
log "=== Discovery complete ==="
log "Written to: $OUT"
cat "$OUT"
