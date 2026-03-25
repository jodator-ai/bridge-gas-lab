# Bridge Gas Lab — Findings Log

This file records running findings, anomalies, and decisions made during lab execution.

---

## Findings

### F-001 — NotSettlementLayer blocks all L1 batch commits
- **Date**: 2026-03-25
- **Phase**: server startup / batch commit
- **Finding**: `commitBatchesSharedBridge` reverted with `0xd0266e26` (selector for `NotSettlementLayer()`). The L1 snapshot had chain 6565 configured as a gateway chain, setting `ZKChainStorage.settlementLayer` to `0xF9F61EA5F5908827e40DabA165aB34269E9386fD` at slot 50 of the diamond proxy.
- **Impact**: Without this fix, the server cannot commit any batch to L1, making the entire lab non-functional.
- **Action**: Used `anvil_setStorageAt` to zero slot 50 on the diamond proxy (`0x4FedB5B234765646F0c18144ea36F00Bc2DAfC8F`). Confirmed via `getSettlementLayer()` returning `address(0)`.

### F-002 — MismatchL2DACommitmentScheme (scheme 4 vs 3)
- **Date**: 2026-03-25
- **Phase**: server batch commit (after F-001 fix)
- **Finding**: The diamond proxy stored `l2DACommitmentScheme = 4 (BlobsZKsyncOS)` but the server with `pubdata_mode: Calldata` sends scheme `3 (BlobsAndPubdataKeccak256)`. This caused batch commit to fail with `MismatchL2DACommitmentScheme`.
- **Impact**: Batch commits fail; server panics and exits.
- **Action**: Impersonated admin account (`0x6a71F328eed5a4909619C75C020Cb3a3827B2697`) on Anvil and called `setDAValidatorPair(rollup_l1_da_validator, 3)` on the diamond proxy. The L2 commitment scheme must match the server's pubdata mode.

### F-003 — pubdata_mode to l2DACommitmentScheme mapping
- **Date**: 2026-03-25
- **Phase**: server configuration research
- **Finding**: ZKsync OS server maps pubdata modes to `L2DACommitmentScheme` values as follows:
  - `Calldata` → `BlobsAndPubdataKeccak256 (3)`
  - `Blobs` → `BlobsZKsyncOS (4)`
  - `Validium` → `EmptyNoDA (1)`
  - Source: `zksync-os-server/lib/types/src/pubdata_mode.rs`
- **Impact**: Critical for operator: the NTV's `setDAValidatorPair` must receive scheme 3 when using Calldata mode.
- **Action**: Documented here. Use scheme 3 in any fresh chain setup with Calldata mode.

### F-004 — ERC20 deposit encoding requires NEW_ENCODING_VERSION (0x01) prefix
- **Date**: 2026-03-25
- **Phase**: erc20-nonbase gas measurement
- **Finding**: `requestL2TransactionTwoBridges` via `L1AssetRouter.bridgehubDeposit` requires the `secondBridgeCalldata` to start with encoding version byte `0x01` (NEW_ENCODING_VERSION). Without it, the call reverts with `UnsupportedEncodingVersion`.
- **Impact**: All ERC20 deposit scripts must prepend `0x01` to the ABI-encoded `(assetId, transferData)`.
- **Action**: `secondBridgeCalldata = 0x01 || abi.encode(assetId, abi.encode(amount, receiver, tokenAddress))` where `tokenAddress` can be `address(0)` if already NTV-registered, or the L1 token address for auto-registration.

### F-005 — First ERC20 deposit is ~14% more expensive than subsequent ones
- **Date**: 2026-03-25
- **Phase**: erc20-nonbase gas measurement
- **Finding**: The first deposit of an ERC20 token through `L1AssetRouter` is more expensive because the `bridgeMintCalldata` includes token metadata (name, symbol, decimals) that the L2 NTV uses to deploy the L2 token contract. Subsequent deposits omit this metadata.
  - First deposit L1 gasUsed: **511,312**
  - Subsequent deposit L1 gasUsed: **~449,139** (avg)
  - Overhead vs eth-base-eoa: +226k first, +165k subsequent
- **Impact**: Any system that deposits an ERC20 for the first time should budget ~15% more gas.
- **Action**: Separate entries in the recommendation matrix for first vs subsequent ERC20 deposits.

### F-006 — Priority queue depth increases L1 gas cost for eth-base-eoa
- **Date**: 2026-03-25
- **Phase**: eth-base-eoa measurement
- **Finding**: The third eth-base-eoa run had gasUsed=335,126 vs 279,447-284,581 for earlier runs. This suggests that as the priority queue depth grows (more unprocessed priority txs), the L1 gas for each new deposit increases.
- **Impact**: Reported median (284,581) is more representative than max. Real-world cost depends on priority queue backlog.
- **Action**: Use median for recommendation matrix. Note the variance in findings.

### F-007 — eth-base-contract case blocked by zero L2 ETH balance
- **Date**: 2026-03-25
- **Phase**: eth-base-contract setup
- **Finding**: Deploying `PayableReceiver` (a contract recipient) on L2 requires ETH for L2 gas. The L2 genesis has zero ETH on the rich account (`0xf39Fd...`). Since our eth-base-eoa deposit sends l2Value=0, no ETH reaches L2.
- **Impact**: Cannot measure gas for contract recipient variant without a funded L2 account.
- **Action**: Mark case as blocked. To unblock: send a full eth-base-eoa deposit with l2Value > 0 (e.g., 0.1 ETH), then deploy PayableReceiver with the funded account. Not critical for core gas matrix.

---

## Gas Measurement Results (2026-03-25)

### Environment
- L1: Anvil (chain 31337, gas price 1.000000008 Gwei)
- L2: ZKsync-OS server v0.18.0, chain 6565, pubdata_mode: Calldata
- gasPerPubdataByteLimit: 800
- Bridgehub: `0x52890e1e831b5c24af44016f0c05615c260109c4`
- Diamond proxy: `0x4FedB5B234765646F0c18144ea36F00Bc2DAfC8F`
- TestERC20 (L1): `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`

### baseCost Formula
At 1 Gwei L1 gas price: `baseCost ≈ l2GasLimit × 262,500 × 1 Gwei`
(Measured empirically: 71875 × 262500 × 10^9 = 18,867,187,500,000 ✓)

### eth-base-eoa
| Run | TX | L1 gasUsed |
|-----|-----|-----------|
| 1 | 0x7050c669... | 284,581 |
| 2 | 0x2895c64c... | 279,447 |
| 3 | 0x8d030a49... | 335,126 |
| **Median** | | **284,581** |

Min l2GasLimit: **71,875**
baseCost at min: 18,867,187,500,000 wei (≈18.9 Gwei-equivalent overhead)

### erc20-nonbase
| Run | Subcase | L1 gasUsed | l2GasLimit |
|-----|---------|-----------|-----------|
| 1 | first-deposit | 511,312 | 200,000 |
| 2 | subsequent | 449,138 | 300,000 |
| 3 | subsequent | 449,139 | 300,000 |

---

## Known Constraints

- Lab is local-only; results reflect the `zksync-os-server` local-chain config in use
- Gas values may differ on mainnet or other ZKsync-compatible chains
- `gasPerPubdata = 800` is fixed for this run — different pubdata pricing changes costs
- Priority queue depth affects L1 gas cost (F-006)
- eth-base-contract and eth-nonbase cases not measured (see F-007)

## Methodology Notes

- All measurements use `cast` against local Anvil + `zksync-os-server`
- No SDK estimation used at any point
- Address discovery is always re-run after each lab reset
- Diamond proxy fixed: settlementLayer=address(0), l2DACommitmentScheme=3 (F-001, F-002)
- The `erc20-nonbase-existing-eoa` case requires a preparatory deposit before measurement
