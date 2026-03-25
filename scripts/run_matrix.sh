#!/usr/bin/env bash
# run_matrix.sh — run all cases and produce the recommendation matrix
#
# Usage:
#   run_matrix.sh [--runs N] [--cases case1,case2,...]
#
# Default: 10 runs per case, all defined cases
#
# Output:
#   results/summary.csv
#   results/recommendation-matrix.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_DIR="$ROOT/results"
RAW_DIR="$RESULTS_DIR/raw"
mkdir -p "$RAW_DIR"

log() { echo "[run_matrix] $*"; }
die() { echo "[run_matrix] ERROR: $*" >&2; exit 1; }

# ── Parse arguments ───────────────────────────────────────────────────────────
RUNS=10
CASE_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --cases) CASE_FILTER="$2"; shift 2 ;;
    *) log "Unknown arg: $1"; shift ;;
  esac
done

log "Matrix run: $RUNS reps per case"
[ "$RUNS" -lt 10 ] && log "WARNING: fewer than 10 runs — confidence will be marked 'medium' or lower"

# ── Determine which cases to run ──────────────────────────────────────────────
if [ -n "$CASE_FILTER" ]; then
  IFS=',' read -ra CASES <<< "$CASE_FILTER"
else
  CASES=()
  while IFS= read -r f; do
    CASES+=("$(basename "$f" .json)")
  done < <(find "$ROOT/cases" -name "*.json" | sort)
fi

log "Cases to run: ${CASES[*]}"

# ── Run all cases ─────────────────────────────────────────────────────────────
declare -A CASE_RESULTS  # case_id -> array of result files

for CASE_ID in "${CASES[@]}"; do
  log ""
  log "=== Running case: $CASE_ID ($RUNS runs) ==="

  CASE_RUN_FILES=()
  FAILED_RUNS=0

  for RUN in $(seq 1 "$RUNS"); do
    log "  Run $RUN/$RUNS..."
    RESULT_FILE="$RAW_DIR/${CASE_ID}_run${RUN}.json"

    if "$ROOT/scripts/run_case.sh" "$CASE_ID" "$RUN" 2>&1; then
      if [ -f "$RESULT_FILE" ]; then
        L2_STATUS=$(jq -r '.l2_status' "$RESULT_FILE")
        if [ "$L2_STATUS" = "0x1" ] || [ "$L2_STATUS" = "1" ]; then
          CASE_RUN_FILES+=("$RESULT_FILE")
          log "  Run $RUN: SUCCESS"
        else
          (( FAILED_RUNS++ )) || true
          log "  Run $RUN: FAILED (L2 status: $L2_STATUS)"
        fi
      fi
    else
      (( FAILED_RUNS++ )) || true
      log "  Run $RUN: FAILED (script error)"
    fi
  done

  log "Case $CASE_ID: ${#CASE_RUN_FILES[@]} successful / $RUNS total"
done

# ── Build recommendation matrix ───────────────────────────────────────────────
log ""
log "=== Building recommendation matrix ==="
"$ROOT/scripts/build_matrix.sh"

log ""
log "=== Matrix run complete ==="
log "Results: $RESULTS_DIR/recommendation-matrix.md"
log "CSV:     $RESULTS_DIR/summary.csv"
