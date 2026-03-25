# ZKsync L1→L2 Deposit Gas Recommendation Matrix

**Environment**: ZKsync OS v0.18.0, Calldata pubdata mode, gasPerPubdata=800
**L1 gas price at time of measurement**: 1.000 Gwei
**L1 chain**: Anvil (chain 31337)
**L2 chain**: 6565 (local ZKsync OS)
**Date**: 2026-03-25

---

## Quick-Reference Matrix

| Deposit Type | Function | Min l2GasLimit | Recommended l2GasLimit | L1 gasUsed (median) | baseCost at rec (1 Gwei) | Notes |
|---|---|---|---|---|---|---|
| ETH deposit (EOA recipient) | `requestL2TransactionDirect` | **71,875** | 80,000 | **284,581** | 21,000,000,000,000 wei | Base case |
| ETH deposit (contract recipient) | `requestL2TransactionDirect` | ~71,875 | 80,000 | N/A | ~21,000,000,000,000 wei | Not measured (L2 deploy blocked) |
| ERC20 deposit — first time | `requestL2TransactionTwoBridges` | unknown | 200,000–300,000 | **511,312** | 52.5–78.75 Gwei×1000 | Includes L2 token deployment cost |
| ERC20 deposit — subsequent | `requestL2TransactionTwoBridges` | unknown | 300,000 | **449,139** | 78,750,000,000,000 wei | Token already on L2 |

---

## Scaling to Other Gas Prices

The formula for `mintValue` is:

```
mintValue = baseCost + l2Value
baseCost  = Bridgehub.l2TransactionBaseCost(chainId, l1GasPrice, l2GasLimit, gasPerPubdata)
```

Empirical fit for this chain config:
```
baseCost ≈ l2GasLimit × 262,500 × l1GasPrice_gwei  (in Gwei units)
```

| l2GasLimit | 10 Gwei L1 gas price | 50 Gwei | 100 Gwei |
|---|---|---|---|
| 71,875 (ETH min) | 188.7 Gwei | 943 Gwei | 1.887 mETH |
| 80,000 (ETH rec) | 210 Gwei | 1,050 Gwei | 2.1 mETH |
| 200,000 (ERC20 first) | 525 Gwei | 2,625 Gwei | 5.25 mETH |
| 300,000 (ERC20 sub) | 787.5 Gwei | 3,937 Gwei | 7.875 mETH |

---

## L1 Gas Budget by Case

The L1 gas figures below are the gas consumed by the **deposit call itself** (not including ERC20 approve or NTV registration):

### eth-base-eoa
- **Median**: 284,581 gas
- **Variance**: 279,447 – 335,126 (N=3)
- **Call**: `Bridgehub.requestL2TransactionDirect(...)`
- **Budget recommendation**: 350,000 gas (1.25× median, covers priority queue depth variance)

### erc20-nonbase-first (first deposit of a given ERC20)
- **Median**: 511,312 gas (N=1)
- **Call**: `Bridgehub.requestL2TransactionTwoBridges(...)`
- **Budget recommendation**: 600,000 gas
- **Note**: Includes L2 `bridgeMintCalldata` with token name/symbol/decimals for L2 NTV to deploy the wrapped token contract. One-time overhead per token per chain.

### erc20-nonbase-existing (subsequent deposits of same ERC20)
- **Median**: 449,139 gas (N=2)
- **Call**: `Bridgehub.requestL2TransactionTwoBridges(...)`
- **Budget recommendation**: 525,000 gas (1.17× median)

---

## Step-by-Step Deposit Guide

### ETH Deposit (base token)

```bash
CHAIN_ID=<your_chain_id>
L1_GAS_PRICE=$(cast gas-price --rpc-url $L1_RPC)
L2_GAS_LIMIT=80000
BASE_COST=$(cast call $BRIDGEHUB \
  "l2TransactionBaseCost(uint256,uint256,uint256,uint256)(uint256)" \
  $CHAIN_ID $L1_GAS_PRICE $L2_GAS_LIMIT 800 --rpc-url $L1_RPC)

MINT_VALUE=$((BASE_COST + L2_VALUE))

cast send $BRIDGEHUB \
  "requestL2TransactionDirect((uint256,uint256,address,uint256,bytes,uint256,uint256,bytes[],address))" \
  "($CHAIN_ID,$MINT_VALUE,$RECIPIENT,$L2_VALUE,0x,$L2_GAS_LIMIT,800,[],0x0000000000000000000000000000000000000000)" \
  --value $MINT_VALUE --rpc-url $L1_RPC --private-key $PK
```

### ERC20 Deposit (non-base token)

```bash
# 1. Register token in NTV (one-time per token)
cast send $NTV "registerToken(address)" $ERC20 --rpc-url $L1_RPC --private-key $PK

# 2. Approve NTV
cast send $ERC20 "approve(address,uint256)" $NTV $AMOUNT --rpc-url $L1_RPC --private-key $PK

# 3. Compute calldata
ASSET_ID=$(cast call $NTV "assetId(address)(bytes32)" $ERC20 --rpc-url $L1_RPC)
TRANSFER_DATA=$(cast abi-encode "f(uint256,address,address)" $AMOUNT $RECIPIENT $ERC20)
INNER=$(cast abi-encode "f(bytes32,bytes)" $ASSET_ID $TRANSFER_DATA)
SECOND_CALLDATA="0x01${INNER:2}"  # Prepend NEW_ENCODING_VERSION byte

# 4. Deposit
L2_GAS_LIMIT=300000
BASE_COST=$(cast call $BRIDGEHUB \
  "l2TransactionBaseCost(uint256,uint256,uint256,uint256)(uint256)" \
  $CHAIN_ID $L1_GAS_PRICE $L2_GAS_LIMIT 800 --rpc-url $L1_RPC)

cast send $BRIDGEHUB \
  "requestL2TransactionTwoBridges((uint256,uint256,uint256,uint256,uint256,address,address,uint256,bytes))" \
  "($CHAIN_ID,$BASE_COST,0,$L2_GAS_LIMIT,800,$RECIPIENT,$ASSET_ROUTER,0,$SECOND_CALLDATA)" \
  --value $BASE_COST --rpc-url $L1_RPC --private-key $PK
```

---

## Key Gotchas

1. **`mintValue` must be exact**: `mintValue = baseCost + l2Value` and `msg.value == mintValue`. Under-funding reverts with `MsgValueMismatch`.

2. **ERC20 secondBridgeCalldata must start with `0x01`**: The `NEW_ENCODING_VERSION` byte is required. Omitting it causes `UnsupportedEncodingVersion` revert.

3. **`transferData` for NTV is `abi.encode(amount, receiver, tokenAddress)`**: Three fields, not two.

4. **Chain config requirements** (local chains only):
   - `settlementLayer` must be `address(0)` for L1 batch commits to work
   - `l2DACommitmentScheme` must be `3` for `pubdata_mode: Calldata`

5. **Priority queue depth increases L1 gas**: The cost of `requestL2TransactionDirect` grows slightly as the priority queue has more unprocessed txs. Budget a 25% safety margin over the base median.

---

## Cases Not Measured

| Case | Reason |
|------|--------|
| eth-base-contract | L2 contract deployment blocked: no ETH on L2 genesis |
| eth-nonbase-eoa | N/A: ETH is the base token for chain 6565, so ETH cannot be a non-base asset on this chain |
| erc20-base-eoa | N/A: base token is ETH, not ERC20 |

---

*Generated by bridge-gas-lab on 2026-03-25. Raw data in `results/raw/`. See `FINDINGS.md` for detailed engineering notes.*
