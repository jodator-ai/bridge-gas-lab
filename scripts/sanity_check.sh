#!/usr/bin/env bash
# sanity_check.sh — verify lab is ready before running any case
# Exits non-zero if any check fails
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L1_RPC="${L1_RPC:-http://localhost:8545}"
L2_RPC="${L2_RPC:-http://localhost:3050}"
DISCOVERY="$ROOT/results/raw/discovery.json"

PASS=0
FAIL=0

log()  { echo "[sanity] $*"; }
ok()   { echo "[sanity] OK   $*"; (( PASS++ )) || true; }
fail() { echo "[sanity] FAIL $*" >&2; (( FAIL++ )) || true; }

rpc_call() {
  local rpc="$1" method="$2" params="${3:-[]}"
  curl -sf --max-time 5 -X POST "$rpc" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" 2>/dev/null
}

# ── 1. L1 RPC responds ────────────────────────────────────────────────────────
if rpc_call "$L1_RPC" "eth_chainId" | jq -e '.result' > /dev/null 2>&1; then
  ok "L1 RPC is responding ($L1_RPC)"
else
  fail "L1 RPC not responding ($L1_RPC)"
fi

# ── 2. L2 RPC responds ────────────────────────────────────────────────────────
if rpc_call "$L2_RPC" "eth_chainId" | jq -e '.result' > /dev/null 2>&1; then
  ok "L2 RPC is responding ($L2_RPC)"
else
  fail "L2 RPC not responding ($L2_RPC)"
fi

# ── 3. Discovery file exists ──────────────────────────────────────────────────
if [ -f "$DISCOVERY" ]; then
  ok "discovery.json exists"
else
  fail "discovery.json missing — run discover_addresses.sh"
fi

# ── 4. Bridgehub is nonzero ───────────────────────────────────────────────────
if [ -f "$DISCOVERY" ]; then
  BRIDGEHUB=$(jq -r '.bridgehub' "$DISCOVERY")
  NULL_ADDR="0x0000000000000000000000000000000000000000"
  if [ "$BRIDGEHUB" != "null" ] && [ "$BRIDGEHUB" != "$NULL_ADDR" ] && [ -n "$BRIDGEHUB" ]; then
    ok "Bridgehub address: $BRIDGEHUB"
  else
    fail "Bridgehub address is null or zero: $BRIDGEHUB"
  fi
fi

# ── 5. Rich account has L1 funds ─────────────────────────────────────────────
if [ -f "$DISCOVERY" ]; then
  RICH=$(jq -r '.rich_account' "$DISCOVERY")
  BAL_HEX=$(rpc_call "$L1_RPC" "eth_getBalance" "[\"$RICH\",\"latest\"]" | jq -r '.result' 2>/dev/null || echo "0x0")
  BAL=$(printf '%d' "$BAL_HEX" 2>/dev/null || echo 0)
  MIN_BAL=1000000000000000000  # 1 ETH
  if [ "$BAL" -gt "$MIN_BAL" ]; then
    ok "Rich account L1 balance: $BAL wei"
  else
    fail "Rich account L1 balance too low: $BAL wei (need > $MIN_BAL)"
  fi
fi

# ── 6. Rich account has L2 funds ─────────────────────────────────────────────
if [ -f "$DISCOVERY" ]; then
  L2_BAL_HEX=$(rpc_call "$L2_RPC" "eth_getBalance" "[\"$RICH\",\"latest\"]" | jq -r '.result' 2>/dev/null || echo "0x0")
  L2_BAL=$(printf '%d' "$L2_BAL_HEX" 2>/dev/null || echo 0)
  if [ "$L2_BAL" -gt 0 ]; then
    ok "Rich account L2 balance: $L2_BAL wei"
  else
    log "WARNING: Rich account L2 balance is 0 — may be OK before first deposit"
  fi
fi

# ── 7. Base cost call succeeds ────────────────────────────────────────────────
if [ -f "$DISCOVERY" ]; then
  BRIDGEHUB=$(jq -r '.bridgehub' "$DISCOVERY")
  L2_CHAIN_ID=$(jq -r '.l2_chain_id' "$DISCOVERY")
  # l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, gasPerPubdata)
  # selector: 0xb473318e
  # Encode: chainId, gasPrice=1gwei, l2GasLimit=200000, gasPerPubdata=800
  CALL_DATA="0xb473318e\
$(printf '%064x' "$L2_CHAIN_ID")\
$(printf '%064x' 1000000000)\
$(printf '%064x' 200000)\
$(printf '%064x' 800)"
  BASE_COST_RESULT=$(rpc_call "$L1_RPC" "eth_call" \
    "[{\"to\":\"$BRIDGEHUB\",\"data\":\"$CALL_DATA\"},\"latest\"]" | jq -r '.result' 2>/dev/null || echo "null")
  if [ "$BASE_COST_RESULT" != "null" ] && [ -n "$BASE_COST_RESULT" ]; then
    BASE_COST_WEI=$(printf '%d' "$BASE_COST_RESULT" 2>/dev/null || echo "decode-error")
    ok "Base cost call returned: $BASE_COST_WEI wei"
  else
    fail "Base cost call failed or returned null"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
log "=== Sanity check summary: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "ABORT: $FAIL sanity check(s) failed. Fix above issues before running matrix."
  exit 1
fi

echo "Lab is ready."
