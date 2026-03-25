# Bridge Gas Lab — Findings Log

This file records running findings, anomalies, and decisions made during lab execution.

## Format

Each entry should include:

- **Date**: ISO date
- **Phase**: which script/step produced the finding
- **Finding**: what was observed
- **Impact**: effect on the matrix or methodology
- **Action**: what was done in response

---

## Findings

_No findings yet. This file will be updated as the lab runs._

---

## Known Constraints

- Lab is local-only; results reflect the `zksync-os-server` local-chain config in use
- Gas values may differ on mainnet or other ZKsync-compatible chains
- `gasPerPubdata = 800` is fixed for this run — different pubdata pricing changes costs

## Methodology Notes

- All measurements use `cast` against local Anvil + `zksync-os-server`
- No SDK estimation used at any point
- Address discovery is always re-run after each lab reset
- The `erc20-nonbase-existing-eoa` case requires a preparatory deposit before measurement
