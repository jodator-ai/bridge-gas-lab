# L1→L2 Bridge Gas Lab

A deterministic lab for measuring ZKsync-compatible L1→L2 deposit gas budgets.

## Purpose

Produce a recommendation matrix with per-route guidance for:

- minimum passing `l2GasLimit`
- observed L2 `gasUsed`
- observed outer L1 `gasUsed`
- `mintValue`
- recommended safety-buffered `l2GasLimit`
- recommended safety-buffered outer L1 `gasLimit`

## Design Principles

- **No SDK**: all measurements use `cast`, `forge`, `bash`, `jq` — never `zksync-js`
- **No protected RPC**: all calls go to local Anvil / zksync-os-server
- **Deterministic**: full reset between case groups
- **Auditable**: every raw result persisted to `results/raw/`
- **Public repos only**: reproducible from open-source repositories

## Routes Covered

| Case ID | Route | Base Token | Recipient |
|---|---|---|---|
| `eth-base-eoa` | `requestL2TransactionDirect` | ETH | EOA |
| `eth-base-contract` | `requestL2TransactionDirect` | ETH | Payable Contract |
| `erc20-base-eoa` | `requestL2TransactionDirect` | ERC20 | EOA |
| `eth-nonbase-eoa` | `requestL2TransactionTwoBridges` | non-ETH | EOA |
| `erc20-nonbase-first-eoa` | `requestL2TransactionTwoBridges` | non-base ERC20 | EOA (first deploy) |
| `erc20-nonbase-existing-eoa` | `requestL2TransactionTwoBridges` | non-base ERC20 | EOA (existing token) |

## Quick Start

```bash
# 1. Install dependencies
./scripts/install_deps.sh

# 2. Clone public repos
./scripts/clone_repos.sh

# 3. Build zksync-os-server
./scripts/build_server.sh

# 4. Start the lab
./scripts/start_lab.sh

# 5. Run discovery
./scripts/discover_addresses.sh

# 6. Run full matrix
./scripts/run_matrix.sh
```

## Workspace Layout

```
bridge-gas-lab/
  README.md
  TEST_PLAN.md              ← full test plan specification
  FINDINGS.md               ← running findings log
  cases/                    ← per-case parameter files
  scripts/
    install_deps.sh
    clone_repos.sh
    build_server.sh
    start_lab.sh
    stop_lab.sh
    reset_lab.sh
    discover_addresses.sh
    build_case_payload.sh
    find_min_l2_gas.sh
    send_case.sh
    find_l2_receipt.sh
    run_case.sh
    run_matrix.sh
  contracts/                ← local test ERC20 contract
  results/
    raw/                    ← one JSON per run
    summary.csv
    recommendation-matrix.md
  repos/                    ← cloned public repositories
```

## Public Repositories Used

| Repo | Purpose |
|---|---|
| `matter-labs/zksync-os-server` | Local lab: Anvil snapshot, sequencer, RPC |
| `matter-labs/zksync-contracts` | Bridge interfaces and validator logic |
| `matter-labs/foundry-zksync` | `forge`, `cast`, ZKsync-compatible tooling |
| `matter-labs/zksync-js` | Reference only — route semantics |

## Fixed Inputs Per Matrix Run

- `gasPerPubdata = 800`
- `operatorTip = 0`
- L1 gas price: fixed per run pass
- Deposit amounts: see `cases/` directory

## Lab Endpoints

- L1 Anvil RPC: `http://localhost:8545`
- L2 zksync-os-server RPC: `http://localhost:3050`

## Results

See `results/recommendation-matrix.md` for the final output table.
Raw measurement files are in `results/raw/`.
