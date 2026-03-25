#!/usr/bin/env bash
# find_min_l2_gas.sh — binary-search for minimum passing l2GasLimit
#
# Usage:
#   find_min_l2_gas.sh <case_id>
#
# Algorithm:
#   1. Start from route lower bound
#   2. Double until dry-run passes
#   3. Binary-search between last-fail and first-pass
#   4. Stop when interval < 5000
#   5. Confirm with 3 dry-runs
#
# Exit codes:
#   0 — minimum found; prints result to stdout and results/raw/min_gas_<case_id>.json
#   1 — failed or case invalid
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_ID="${1:?Usage: $0 <case_id>}"

L1_RPC="${L1_RPC:-http://localhost:8545}"
DISCOVERY="$ROOT/results/raw/discovery.json"
CASE_FILE="$ROOT/cases/$CASE_ID.json"
OUT="$ROOT/results/raw/min_gas_${CASE_ID}.json"
mkdir -p "$(dirname "$OUT")"

log()  { echo "[find_min_gas:$CASE_ID] $*"; }
die()  { echo "[find_min_gas:$CASE_ID] ERROR: $*" >&2; exit 1; }

[ -f "$DISCOVERY" ] || die "discovery.json missing"
[ -f "$CASE_FILE" ] || die "case file missing: $CASE_FILE"

ROUTE=$(jq -r '.route' "$CASE_FILE")

# ── Initial lower bounds by route ─────────────────────────────────────────────
case "$ROUTE" in
  eth-base)      LOWER=100000 ;;
  erc20-base)    LOWER=300000 ;;
  eth-nonbase)   LOWER=500000 ;;
  erc20-nonbase*) LOWER=1000000 ;;
  *)             LOWER=200000 ;;
esac

CONVERGENCE_THRESHOLD=5000
CONFIRM_RUNS=3

log "Route: $ROUTE | Starting lower bound: $LOWER"

# ── Dry-run function ──────────────────────────────────────────────────────────
# Returns: "pass", "out_of_gas", "value_error", or "other:<reason>"
dry_run() {
  local gas_limit="$1"

  # Build payload for this gas limit
  PAYLOAD_OUT=$("$ROOT/scripts/build_case_payload.sh" "$CASE_ID" "$gas_limit" 2>/dev/null)
  PAYLOAD_FILE="$ROOT/results/raw/payload_${CASE_ID}.json"

  CALLDATA=$(jq -r '.calldata' "$PAYLOAD_FILE")
  BRIDGEHUB=$(jq -r '.bridgehub' "$PAYLOAD_FILE")
  SENDER=$(jq -r '.sender' "$PAYLOAD_FILE")
  MSG_VALUE=$(jq -r '.msgValue' "$PAYLOAD_FILE")
  MSG_VALUE_HEX="0x$(printf '%x' "$MSG_VALUE")"

  # Perform eth_call (dry run)
  RESULT=$(curl -sf -X POST "$L1_RPC" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{
      \"from\":\"$SENDER\",
      \"to\":\"$BRIDGEHUB\",
      \"data\":\"$CALLDATA\",
      \"value\":\"$MSG_VALUE_HEX\",
      \"gas\":\"0x$(printf '%x' 5000000)\"
    },\"latest\"],\"id\":1}" 2>/dev/null)

  # Check for errors
  ERROR=$(echo "$RESULT" | jq -r '.error // null')
  if [ "$ERROR" = "null" ]; then
    echo "pass"
    return
  fi

  ERROR_MSG=$(echo "$RESULT" | jq -r '.error.message // .error // "unknown"')
  ERROR_DATA=$(echo "$RESULT" | jq -r '.error.data // ""')

  # Classify the error
  FULL_ERROR="${ERROR_MSG} ${ERROR_DATA}"
  if echo "$FULL_ERROR" | grep -qi 'ValidateTxnNotEnoughGas\|not enough gas\|insufficient.*gas'; then
    echo "out_of_gas"
  elif echo "$FULL_ERROR" | grep -qi 'MsgValueTooLow\|msg.value too low'; then
    echo "value_error:MsgValueTooLow"
  elif echo "$FULL_ERROR" | grep -qi 'MsgValueMismatch\|msg.*value.*mismatch'; then
    echo "value_error:MsgValueMismatch"
  else
    echo "other:$(echo "$ERROR_MSG" | tr '\n' ' ' | cut -c1-100)"
  fi
}

# ── Phase 1: Exponential search for upper bound ───────────────────────────────
log "Phase 1: exponential search..."
CURRENT=$LOWER
LAST_FAIL=0
FIRST_PASS=0

while true; do
  log "  Trying l2GasLimit=$CURRENT..."
  RESULT=$(dry_run "$CURRENT")
  log "  Result: $RESULT"

  case "$RESULT" in
    pass)
      FIRST_PASS=$CURRENT
      log "  First pass at $FIRST_PASS"
      break
      ;;
    out_of_gas)
      LAST_FAIL=$CURRENT
      CURRENT=$(( CURRENT * 2 ))
      if [ "$CURRENT" -gt 50000000 ]; then
        die "l2GasLimit exceeded 50M without finding a passing value — case may be invalid"
      fi
      ;;
    value_error:*)
      die "Value math error: $RESULT — fix mintValue/msgValue before continuing gas search"
      ;;
    other:*)
      die "Unexpected revert: $RESULT — marking case invalid"
      ;;
  esac
done

# If lower bound already passed, we can skip binary search
if [ "$LAST_FAIL" -eq 0 ]; then
  log "Lower bound $LOWER already passes — minimum is $FIRST_PASS"
  MIN_GAS=$FIRST_PASS
else
  # ── Phase 2: Binary search ────────────────────────────────────────────────
  log "Phase 2: binary search between $LAST_FAIL (fail) and $FIRST_PASS (pass)..."

  LOW=$LAST_FAIL
  HIGH=$FIRST_PASS

  while [ $(( HIGH - LOW )) -gt $CONVERGENCE_THRESHOLD ]; do
    MID=$(( (LOW + HIGH) / 2 ))
    log "  Binary: low=$LOW high=$HIGH mid=$MID"
    RESULT=$(dry_run "$MID")
    log "  Result: $RESULT"
    case "$RESULT" in
      pass)
        HIGH=$MID
        ;;
      out_of_gas)
        LOW=$MID
        ;;
      value_error:*|other:*)
        die "Unexpected result during binary search: $RESULT"
        ;;
    esac
  done

  MIN_GAS=$HIGH
  log "Binary search converged: minimum ≈ $MIN_GAS (interval [$LOW,$HIGH])"
fi

# ── Phase 3: Confirm with multiple dry-runs ───────────────────────────────────
log "Phase 3: confirming with $CONFIRM_RUNS dry-runs at $MIN_GAS..."
CONFIRM_PASS=0
for i in $(seq 1 $CONFIRM_RUNS); do
  RESULT=$(dry_run "$MIN_GAS")
  if [ "$RESULT" = "pass" ]; then
    (( CONFIRM_PASS++ )) || true
    log "  Confirm $i/$CONFIRM_RUNS: pass"
  else
    log "  Confirm $i/$CONFIRM_RUNS: $RESULT"
  fi
done

if [ "$CONFIRM_PASS" -ne "$CONFIRM_RUNS" ]; then
  log "WARNING: only $CONFIRM_PASS/$CONFIRM_RUNS confirmations passed — adding 10% buffer"
  MIN_GAS=$(python3 -c "import math; print(math.ceil($MIN_GAS * 1.1))")
fi

log "Minimum passing l2GasLimit: $MIN_GAS"

# ── Write result ──────────────────────────────────────────────────────────────
jq -n \
  --arg case_id "$CASE_ID" \
  --arg route "$ROUTE" \
  --argjson min_gas "$MIN_GAS" \
  --argjson last_fail "$LAST_FAIL" \
  --argjson first_pass "$FIRST_PASS" \
  --argjson confirm_pass "$CONFIRM_PASS" \
  --argjson confirm_runs "$CONFIRM_RUNS" \
  '{
    case_id: $case_id,
    route: $route,
    min_passing_l2GasLimit: $min_gas,
    search_last_fail: $last_fail,
    search_first_pass: $first_pass,
    confirm_pass: $confirm_pass,
    confirm_runs: $confirm_runs
  }' > "$OUT"

echo "$MIN_GAS"
