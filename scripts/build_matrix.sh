#!/usr/bin/env bash
# build_matrix.sh — aggregate raw results into summary.csv and recommendation-matrix.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="$ROOT/results/raw"
SUMMARY_CSV="$ROOT/results/summary.csv"
MATRIX_MD="$ROOT/results/recommendation-matrix.md"

log() { echo "[build_matrix] $*"; }

# ── Collect all run files ─────────────────────────────────────────────────────
mapfile -t RUN_FILES < <(find "$RAW_DIR" -name '*_run*.json' | sort)

if [ ${#RUN_FILES[@]} -eq 0 ]; then
  log "No run files found in $RAW_DIR"
  exit 0
fi

log "Processing ${#RUN_FILES[@]} run files..."

# ── Python aggregation script ─────────────────────────────────────────────────
python3 - "$RAW_DIR" "$SUMMARY_CSV" "$MATRIX_MD" << 'PYEOF'
import sys
import json
import math
import glob
import os
from collections import defaultdict
from datetime import datetime, timezone

raw_dir, summary_csv, matrix_md = sys.argv[1], sys.argv[2], sys.argv[3]

# Load all run results
runs = []
for f in sorted(glob.glob(os.path.join(raw_dir, "*_run*.json"))):
    try:
        with open(f) as fh:
            data = json.load(fh)
            data["_file"] = f
            runs.append(data)
    except Exception as e:
        print(f"WARNING: Could not load {f}: {e}", file=sys.stderr)

# Group by case_id
by_case = defaultdict(list)
for r in runs:
    by_case[r.get("case_id", "unknown")].append(r)

# Determine success
def is_success(r):
    status = r.get("l2_status", "")
    return status in ("0x1", "1", 1)

# Confidence rules
def get_confidence(successful_runs, total_runs, variance_pct):
    if successful_runs >= 10 and variance_pct < 5:
        return "high"
    elif successful_runs >= 5 and variance_pct < 20:
        return "medium"
    else:
        return "low"

def variance_pct(values):
    if not values or len(values) < 2:
        return 0
    avg = sum(values) / len(values)
    if avg == 0:
        return 0
    variance = sum((v - avg) ** 2 for v in values) / len(values)
    std = math.sqrt(variance)
    return (std / avg) * 100

# CSV header
csv_rows = ["case_id,run_id,route,base_token_kind,recipient_kind,token_mode,deposit_amount,"
            "gasPerPubdata,operatorTip,fixedL1GasPrice,min_passing_l2GasLimit,"
            "baseCost,mintValue,msgValue,l1_gas_used,l1_effective_gas_price,"
            "l2_gas_used,l2_status,l1_tx_hash,l2_tx_hash,notes"]

matrix_rows = []

for case_id, case_runs in sorted(by_case.items()):
    successful = [r for r in case_runs if is_success(r)]
    total = len(case_runs)
    n_ok = len(successful)

    # Write CSV rows for all runs
    for r in case_runs:
        csv_rows.append(",".join([
            str(r.get(k, "")) for k in [
                "case_id", "run_id", "route", "base_token_kind", "recipient_kind",
                "token_mode", "deposit_amount", "gasPerPubdata", "operatorTip",
                "fixedL1GasPrice", "min_passing_l2GasLimit", "baseCost", "mintValue",
                "msgValue", "l1_gas_used", "l1_effective_gas_price", "l2_gas_used",
                "l2_status", "l1_tx_hash", "l2_tx_hash", "notes"
            ]
        ]))

    if not successful:
        print(f"WARNING: No successful runs for {case_id} — skipping matrix row", file=sys.stderr)
        # Still add a placeholder row
        r0 = case_runs[0] if case_runs else {}
        matrix_rows.append({
            "case_id": case_id,
            "route": r0.get("route", ""),
            "base_token_kind": r0.get("base_token_kind", ""),
            "recipient_kind": r0.get("recipient_kind", ""),
            "token_mode": r0.get("token_mode", ""),
            "deposit_amount": r0.get("deposit_amount", ""),
            "min_passing_l2GasLimit": "N/A",
            "max_l2_gasUsed": "N/A",
            "max_l1_gasUsed": "N/A",
            "recommended_l2GasLimit": "N/A",
            "recommended_l1GasLimit": "N/A",
            "baseCost_range": "N/A",
            "confidence": "low",
            "runs": f"0/{total}",
        })
        continue

    # Aggregate max values
    l2_gas_values = [r.get("l2_gas_used", 0) for r in successful if r.get("l2_gas_used")]
    l1_gas_values = [r.get("l1_gas_used", 0) for r in successful if r.get("l1_gas_used")]
    min_gas_values = [r.get("min_passing_l2GasLimit", 0) for r in successful]
    base_cost_values = [r.get("baseCost", 0) for r in successful]

    max_min_l2_gas = max(min_gas_values) if min_gas_values else 0
    max_l2_gas = max(l2_gas_values) if l2_gas_values else 0
    max_l1_gas = max(l1_gas_values) if l1_gas_values else 0
    min_base_cost = min(base_cost_values) if base_cost_values else 0
    max_base_cost = max(base_cost_values) if base_cost_values else 0

    # Determine buffer multiplier
    route = case_runs[0].get("route", "")
    token_mode = case_runs[0].get("token_mode", "na")
    is_first_deploy = "first" in token_mode or "first" in case_id

    l2_buffer = 1.50 if is_first_deploy else 1.25
    l1_buffer = 1.25

    rec_l2 = math.ceil(max_min_l2_gas * l2_buffer) if max_min_l2_gas > 0 else "N/A"
    rec_l1 = math.ceil(max_l1_gas * l1_buffer) if max_l1_gas > 0 else "N/A"

    # Variance for confidence
    l2_var = variance_pct(min_gas_values)
    conf = get_confidence(n_ok, total, l2_var)

    base_cost_range = f"{min_base_cost}-{max_base_cost}" if min_base_cost != max_base_cost else str(min_base_cost)

    matrix_rows.append({
        "case_id": case_id,
        "route": route,
        "base_token_kind": case_runs[0].get("base_token_kind", ""),
        "recipient_kind": case_runs[0].get("recipient_kind", ""),
        "token_mode": token_mode,
        "deposit_amount": case_runs[0].get("deposit_amount", ""),
        "min_passing_l2GasLimit": max_min_l2_gas,
        "max_l2_gasUsed": max_l2_gas,
        "max_l1_gasUsed": max_l1_gas,
        "recommended_l2GasLimit": rec_l2,
        "recommended_l1GasLimit": rec_l1,
        "baseCost_range": base_cost_range,
        "confidence": conf,
        "runs": f"{n_ok}/{total}",
    })

# Write CSV
with open(summary_csv, "w") as fh:
    fh.write("\n".join(csv_rows) + "\n")
print(f"Written: {summary_csv}")

# Write Markdown matrix
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
cols = [
    "case_id", "route", "base_token_kind", "recipient_kind", "token_mode",
    "deposit_amount", "min_passing_l2GasLimit", "max_l2_gasUsed", "max_l1_gasUsed",
    "recommended_l2GasLimit", "recommended_l1GasLimit", "baseCost_range", "confidence", "runs"
]
header = "| " + " | ".join(cols) + " |"
sep    = "| " + " | ".join(["---"] * len(cols)) + " |"

md_lines = [
    "# L1→L2 Bridge Gas Recommendation Matrix",
    "",
    f"Generated: {now}",
    "",
    "## Matrix",
    "",
    header,
    sep,
]
for row in matrix_rows:
    md_lines.append("| " + " | ".join(str(row.get(c, "")) for c in cols) + " |")

md_lines += [
    "",
    "## Buffer Methodology",
    "",
    "| Route type | l2GasLimit buffer | l1GasLimit buffer |",
    "| --- | --- | --- |",
    "| Stable routes (eth-base, eth-nonbase, erc20-base, erc20-nonbase-existing) | 1.25× | 1.25× |",
    "| First-deploy ERC20 routes (erc20-nonbase-first) | 1.50× | 1.25× |",
    "",
    "## Confidence Labels",
    "",
    "| Label | Criteria |",
    "| --- | --- |",
    "| `high` | ≥10/10 successful runs, variance < 5% |",
    "| `medium` | ≥5 successful runs, variance < 20% |",
    "| `low` | Fewer runs, high variance, or manual intervention required |",
    "",
    "## Fixed Inputs",
    "",
    "- `gasPerPubdata = 800`",
    "- `operatorTip = 0`",
    "- All measurements on local Anvil + zksync-os-server lab",
    "- Client tooling: `cast`, `bash`, `jq`",
    "- No SDK estimation used",
]

with open(matrix_md, "w") as fh:
    fh.write("\n".join(md_lines) + "\n")
print(f"Written: {matrix_md}")
PYEOF

log ""
log "=== Matrix build complete ==="
log "CSV:    $SUMMARY_CSV"
log "Matrix: $MATRIX_MD"
