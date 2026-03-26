# ZKsync L1→L2 Bridge Deposit Flows

An ELI5-level explanation of what happens during a deposit, which contracts are
involved, where gas comes from, and what affects consumption.

---

## The Big Picture

Depositing means: you lock assets on L1, and ZKsync OS mints/credits them on L2.
There is no direct L1↔L2 call — instead you create a **priority transaction** on
L1 that gets added to a queue, and the sequencer picks it up and executes it on L2.

You pay **two separate gas bills**:
- **L1 gas** — for the Ethereum transaction that locks your funds and enqueues the request
- **L2 gas (baseCost)** — pre-paid on L1 in ETH, spent when the sequencer executes your tx on L2

---

## Route 1: ETH deposit (`eth-base`)

```
You
 │
 │  wallet.deposit({ token: ETH, amount: 0.1 ETH, value: baseCost + 0.1 ETH })
 ▼
Bridgehub (L1)
 │  requestL2TransactionDirect(chainId, mintValue, to, l2Value, calldata='0x', l2GasLimit, ...)
 │
 │  checks:
 │    ✓ msg.value == mintValue (baseCost + l2Value)
 │    ✓ l2GasLimit × gasPerPubdata is not too small
 │    ✓ baseCost matches l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, gasPerPubdata)
 │
 ├─→ L1NTV (NativeTokenVault)
 │     locks your ETH (just holds the msg.value)
 │
 └─→ Diamond Proxy / Mailbox (L1)
       writes priority tx to the priority queue
       emits NewPriorityRequest event

           ↓  (sequencer polls the queue)

Bootloader (L2)
 │  executes the priority tx:
 │    credits `l2Value` ETH to address `to`
 │    calldata is '0x' → nothing else happens
 │
 └─→ done. ETH appears in your L2 wallet.
```

**Where gas comes from:**
- L1 gas: writing the priority tx to storage (priority queue slot), emitting the event, the
  validation checks — roughly 280–340K gas
- L2 gas (baseCost): bootloader credits ETH — this is very cheap (~71K gas minimum), dominated
  by the overhead of running any priority tx at all

---

## Route 2: ERC20 deposit (`erc20-nonbase`)

More complex because the L2 side needs to deploy or mint a wrapped token contract.

```
You
 │
 │  wallet.deposit({ token: USDC, amount: 1000, approveERC20: true })
 ▼
L1AssetRouter (a.k.a. L1SharedBridge)
 │  ERC20.transferFrom(you → L1NTV)      ← this is where the token is locked
 │
 └─→ Bridgehub (L1)
       requestL2TransactionTwoBridges(...)
       │
       │  checks (same as above):
       │    ✓ msg.value == baseCost  (no ETH transferred to L2 for ERC20)
       │    ✓ l2GasLimit is sufficient
       │
       ├─→ L1NTV
       │     holds the ERC20 tokens
       │
       └─→ Diamond Proxy / Mailbox (L1)
             writes priority tx to the priority queue
             caller is aliased (L1AssetRouter address + alias offset)

                 ↓  (sequencer picks it up)

Bootloader (L2)
 │  executes the priority tx with the aliased caller:
 │    calls L2AssetRouter.finalizeDeposit(sender, receiver, token, amount, bridgeData)
 │
 └─→ L2NTV (NativeTokenVault on L2)
       IF first deposit for this token:
         deploys a new ERC20 contract on L2 (BridgedStandardERC20)
         stores name/symbol/decimals from bridgeData
       THEN:
         mints `amount` tokens to `receiver`
```

**Where gas comes from:**
- L1 gas: same priority queue write + the extra `secondBridgeCall` to L1AssetRouter —
  roughly 450–510K gas (first deposit) or 440–500K (subsequent)
- L2 gas (baseCost): significantly more than ETH because of `finalizeDeposit` call + token
  mint, and especially the **contract deployment on first deposit** (~200K+ L2 gas minimum)

---

## What baseCost Actually Is

```
baseCost = l2GasLimit × gasPrice_on_L1 × overhead_factor
```

The Bridgehub formula (implemented in the diamond proxy) at `gasPerPubdata=800`:

```
baseCost ≈ l2GasLimit × 262,500 × l1GasPrice_in_gwei  (in wei)
```

You pre-pay this on L1. The sequencer is compensated from this pool for executing your L2 tx.
If you set `l2GasLimit` too low, the L2 tx runs out of gas and reverts — but your assets are
**not lost** (the failed deposit is claimable back on L1).

---

## What Drives Gas Consumption

| Factor | Effect on L1 gas | Effect on L2 gas (baseCost) |
|---|---|---|
| Priority queue depth | +0–20% (more slots to update) | none |
| First vs subsequent ERC20 | +~14% (extra `bridgeData` calldata) | +large (token contract deployment) |
| ETH vs ERC20 | ETH ~30% cheaper | ETH much cheaper (no finalizeDeposit) |
| Recipient is contract | blocked† | none |
| `l2GasLimit` value | none (not stored on L1) | scales baseCost linearly |
| `gasPerPubdataByte` | none | scales baseCost linearly |
| L1 base fee | scales your L1 fee | scales baseCost (same formula) |

† ETH→contract on L2 fails at the `l2Value > 0` check because L2 ETH balance is zero until the
deposit lands — chicken-and-egg. See FINDINGS.md F-007.

---

## The Two Numbers You Control

```
l2GasLimit      — budget for the L2 execution (too low → L2 reverts, assets recoverable)
overrides.value — must equal mintValue exactly (too low → L1 reverts immediately)

mintValue = baseCost + operatorTip + l2Value
          = (l2GasLimit × gasPrice × factor) + 0 + (ETH amount if base token)
```

`getDepositGasParams()` in `ts-gas-tool/` computes both from the current L1 gas price so you
never have to calculate this manually.

---

## Where Prividium Fits

Prividium adds an **authorization layer in front of the L2 RPC**. It does not change the
contracts or the deposit flow at all — it only controls who can query L2 state (balances, gas
estimates). The actual L1 transactions (locking funds, paying baseCost) bypass Prividium
entirely and go straight to Ethereum. This is why:

- `zks_estimateGasL1ToL2` (L2 gas estimation) may fail on a restricted node
- `l2TransactionBaseCost` (L1 Bridgehub query) always works regardless of Prividium
- Deposits can technically succeed even if the L2 RPC is unreachable — you just can't verify
  the result without it
