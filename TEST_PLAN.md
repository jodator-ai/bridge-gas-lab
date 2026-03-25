# L1→L2 Bridge Gas Lab — Test Plan

## Purpose

This document describes a lab-only test plan for producing a recommendation matrix for L1→L2 deposit gas budgeting on
a compatible ZKsync-based L2.

The plan is intentionally:

- independent of particular L2
- independent of `zksync-js`
- executable from public repositories only
- suitable for an autonomous agent running on a VPS

The output is a recommendation matrix with per-route guidance for:

- minimum passing `l2GasLimit`
- observed L2 `gasUsed`
- observed outer L1 `gasUsed`
- `mintValue`
- recommended safety-buffered `l2GasLimit`
- recommended safety-buffered outer L1 `gasLimit`

## Scope

Covers only deposit gas budgeting on a compatible L2.

Does **not** cover:

- frontend or SDK integration
- protected RPC method behavior
- E2E app testing

## Public Repositories

| Repo | Use |
|---|---|
| `https://github.com/matter-labs/zksync-os-server` | Local lab: Anvil snapshot, sequencer, RPC |
| `https://github.com/matter-labs/zksync-contracts` | Bridge interfaces and validator logic |
| `https://github.com/matter-labs/foundry-zksync` | `forge`, `cast`, ZKsync-compatible tooling |
| `https://github.com/matter-labs/zksync-js` | Reference only — route semantics |

## Core Principle

Measure the underlying chain directly. Do not rely on protected RPC, SDK estimation logic, or frontend flows.

Measure on a deterministic local lab:

- L1: Anvil loaded from `zksync-os-server` snapshot
- L2: `zksync-os-server`
- client tooling: `cast`, `forge`, `bash`, `jq`

## What Must Be Measured

For each deposit route, measure three separate quantities:

1. Minimum passing `l2GasLimit`
2. Actual L2 `gasUsed`
3. Outer L1 transaction `gasUsed`

Also record:

- `gasPerPubdata`
- `operatorTip`
- `mintValue`
- `msg.value`
- base cost from `l2TransactionBaseCost(...)`

## Route Definitions

### `eth-base`

- L1 entrypoint: `Bridgehub.requestL2TransactionDirect`
- deposit asset: ETH
- target chain base token: ETH
- `mintValue = baseCost + operatorTip + l2Value`
- `msg.value = mintValue`

### `erc20-base`

- L1 entrypoint: `Bridgehub.requestL2TransactionDirect`
- deposit asset: ERC20
- target chain base token: same ERC20
- `mintValue = baseCost + operatorTip + depositAmount`
- `msg.value = 0`
- requires token approval

### `eth-nonbase`

- L1 entrypoint: `Bridgehub.requestL2TransactionTwoBridges`
- deposit asset: ETH
- target chain base token: not ETH
- `mintValue = baseCost + operatorTip`
- `msg.value = depositAmount`
- may require base-token approval for fees

### `erc20-nonbase`

- L1 entrypoint: `Bridgehub.requestL2TransactionTwoBridges`
- deposit asset: non-base ERC20
- target chain base token: not the deposit token
- `mintValue = baseCost + operatorTip`
- `msg.value` depends on target chain base token type
- requires deposit-token approval
- first deposit of a token to L2 must be measured separately from later deposits

## Minimum Case Matrix

| Case ID | Route | Notes |
|---|---|---|
| `eth-base-eoa` | `eth-base` | EOA recipient |
| `eth-base-contract` | `eth-base` | Payable contract recipient |
| `erc20-base-eoa` | `erc20-base` | EOA recipient |
| `eth-nonbase-eoa` | `eth-nonbase` | EOA recipient |
| `erc20-nonbase-first-eoa` | `erc20-nonbase` | First token deploy on L2 |
| `erc20-nonbase-existing-eoa` | `erc20-nonbase` | Existing token on L2 |

Priority order if time-constrained:

1. `eth-base`
2. `erc20-nonbase-first-deploy`
3. `erc20-nonbase-existing-token`

## Lab Architecture

### L1

Anvil loaded from `zksync-os-server/local-chains/.../l1-state.json.gz`.

Port: `8545`

### L2

`zksync-os-server` with local-chain config.

Port: `3050`

### Client Tools

- `cast`
- `forge`
- `bash`
- `jq`

## Fixed Inputs Per Matrix Run

- `gasPerPubdata = 800`
- `operatorTip = 0`
- fixed L1 gas price per pass
- fixed deposit amounts per case (see `cases/`)

Initial deposit amounts:

- ETH direct: `50 wei` and `0.01 ETH`
- ERC20: small integer amount and practical amount

## Discovery Requirements

The lab discovers all addresses dynamically at runtime.

Required discoveries:

| Field | Source |
|---|---|
| L2 chain ID | `eth_chainId` on L2 RPC |
| Bridgehub address | `zks_getBridgehubContract` |
| Bridgehub asset router | `Bridgehub.assetRouter()` |
| Native token vault | asset router getter |
| L2 native token vault | if needed |
| Base token on L1 | Bridgehub or chain config |

Output: `results/raw/discovery.json`

## Startup Procedure

1. Clone public repositories
2. Build `zksync-os-server`
3. Decompress chosen `l1-state.json.gz`
4. Start Anvil on `8545` using decompressed state
5. Start `zksync-os-server` on `3050`
6. Wait until both RPCs respond
7. Run discovery
8. Run sanity dry-run

## Sanity Checks

Before any case run, verify:

- L1 RPC responds
- L2 RPC responds
- Rich account has L1 funds
- Rich account has L2 funds
- `zks_getBridgehubContract` returns nonzero address
- Base-cost call succeeds

Abort the run if any check fails.

## Route Payload Construction

Manually construct L1 calldata using:

- `cast abi-encode`
- `cast call`
- `cast send`

No SDK helpers for route encoding or gas estimation.

## Real Test Method

For each case:

1. Reset the lab to a known state
2. Re-run discovery
3. Construct route-specific request payload manually
4. Pick a candidate `l2GasLimit`
5. Call Bridgehub `l2TransactionBaseCost` with fixed L1 gas price
6. Compute `baseCost`, `mintValue`, `msg.value`
7. Ensure required approvals are in place
8. Dry-run the Bridgehub call using `cast call`
9. If dry-run fails with `ValidateTxnNotEnoughGas`, increase `l2GasLimit`
10. Repeat until minimum passing `l2GasLimit` found
11. Send one real L1 transaction
12. Wait for L1 receipt
13. Find corresponding L2 receipt
14. Record all measurements
15. Repeat from fresh state

## Searching For Minimum Passing `l2GasLimit`

### Initial Lower Bounds

| Route | Lower Bound |
|---|---|
| `eth-base` | `100_000` |
| `erc20-base` | `300_000` |
| `eth-nonbase` | `500_000` |
| `erc20-nonbase` | `1_000_000` |

### Search Algorithm

1. Try lower bound
2. If fails with `ValidateTxnNotEnoughGas`, double it
3. Continue doubling until call passes
4. Binary-search between first failing and first passing point
5. Stop when interval width < `5_000`
6. Confirm with 3 repeated dry-runs

### Revert Classification

| Revert | Action |
|---|---|
| `ValidateTxnNotEnoughGas` | Raise `l2GasLimit`, continue search |
| `MsgValueTooLow` | Fix value math, restart |
| `MsgValueMismatch` | Fix value math, restart |
| Other | Record, mark case invalid, stop |

## Measuring Outer L1 Cost

From L1 receipt record:

- `gasUsed`
- `effectiveGasPrice`
- `feePaid = gasUsed * effectiveGasPrice`

## Measuring Inner L2 Cost

After each real deposit, poll L2 blocks and map the next priority transaction.

Record:

- `l2_tx_hash`
- `gasUsed`
- `status`

## Reset Strategy

Full reset between top-level case groups.

Groups:

| Group | Reset Type |
|---|---|
| ETH and direct cases | Full restart |
| ERC20 first-deploy cases | Full restart |
| ERC20 existing-token cases | Reset + preparatory deposit |

For `existing-token` case: reset → preparatory token deposit → measure.

## ERC20 Strategy

Deploy a simple local test ERC20 on L1. Mint to rich account.

Minimum token interface:

- `mint(address,uint256)`
- `approve(address,uint256)`
- `balanceOf(address)`

Contract source in `contracts/`.

## Raw Output Format

Per-run JSON with fields:

```json
{
  "case_id": "",
  "timestamp": "",
  "protocol_version": "",
  "chain_id": "",
  "base_token_kind": "",
  "route": "",
  "token_mode": "",
  "recipient_kind": "",
  "deposit_amount": "",
  "gasPerPubdata": 800,
  "operatorTip": 0,
  "fixedL1GasPrice": "",
  "min_passing_l2GasLimit": "",
  "baseCost": "",
  "mintValue": "",
  "msgValue": "",
  "l1_tx_hash": "",
  "l1_gas_used": "",
  "l1_effective_gas_price": "",
  "l2_tx_hash": "",
  "l2_gas_used": "",
  "l2_status": "",
  "notes": ""
}
```

## Repetition Requirements

- Minimum: 10 fresh-state repetitions per row
- Time-constrained minimum: 5 repetitions (mark confidence lower)

## Building The Recommendation Matrix

Per row, compute:

- `max_min_passing_l2GasLimit`
- `max_observed_l1GasUsed`
- `max_observed_l2GasUsed`

Derive:

| Metric | Formula |
|---|---|
| `recommended_l2GasLimit` (stable) | `ceil(max_min_passing_l2GasLimit * 1.25)` |
| `recommended_l2GasLimit` (first-deploy ERC20) | `ceil(max_min_passing_l2GasLimit * 1.50)` |
| `recommended_l1GasLimit` | `ceil(max_observed_l1GasUsed * 1.25)` |

## Confidence Rules

| Label | Criteria |
|---|---|
| `high` | ≥10/10 successful runs, small variance |
| `medium` | Fewer runs or moderate variance |
| `low` | Manual intervention, significant spread, incomplete correlation |

## Acceptance Criteria

A row is accepted only if:

- All repeated runs succeed
- No accepted run reverts with `ValidateTxnNotEnoughGas`
- L2 receipt found for every real send
- One extra confirmation run succeeds with final recommendation
- Raw JSON data preserved for audit

## Final Deliverables

- `results/raw/` — one JSON per run
- `results/summary.csv`
- `results/recommendation-matrix.md`

## Non-Goals

- Private Docker images
- Protected RPC
- `zksync-js` execution paths
- Frontend or browser testing
