import type { BigNumber } from 'ethers';
import type * as ethers from 'ethers';
import type { Provider as ZkProvider } from 'zksync-ethers';

// ─── Chain configuration ──────────────────────────────────────────────────────

/**
 * Static configuration for a ZKsync chain.
 * These values come from chain deployment / discovery.
 */
export interface ChainConfig {
  /** L2 chain ID (e.g. 6565 local, 300 ZKsync Sepolia, 324 ZKsync Era mainnet) */
  l2ChainId: number;

  /**
   * Address of the Bridgehub contract on L1.
   * Query: `Bridgehub.getHyperchain(l2ChainId)` gives the diamond proxy.
   */
  bridgehubAddress: string;

  /**
   * Address of the L1AssetRouter (a.k.a. L1SharedBridge).
   * Used as `secondBridgeAddress` for ERC20 non-base deposits.
   */
  assetRouterL1Address: string;

  /**
   * Address of the L1 NativeTokenVault (NTV).
   * ERC20 tokens must be `registerToken`'d here before first deposit.
   */
  nativeTokenVaultL1Address: string;

  /**
   * L1 address of the chain's base token.
   * Use `0x0000000000000000000000000000000000000001` for ETH-based chains.
   */
  baseTokenL1Address: string;

  /** Ethers provider for the L1 network */
  l1Provider: ethers.providers.Provider;

  /** ZKsync provider for the L2 network */
  l2Provider: ZkProvider;
}

// ─── Deposit request types ────────────────────────────────────────────────────

/**
 * Which bridge route to use:
 * - `eth-base`    → ETH deposit on an ETH-based chain via requestL2TransactionDirect
 * - `erc20-base`  → ERC20 base token deposit via requestL2TransactionDirect (rare)
 * - `erc20-nonbase` → ERC20 non-base token via requestL2TransactionTwoBridges
 *
 * Note: `eth-nonbase` (ETH on a chain whose base is an ERC20) also uses
 * requestL2TransactionTwoBridges and is treated as `erc20-nonbase` here.
 */
export type DepositType = 'eth-base' | 'erc20-base' | 'erc20-nonbase';

export interface DepositRequest {
  /** Which bridge route (determines function and calldata shape) */
  type: DepositType;

  /** Token address on L1.
   *  - ETH: `0x0000000000000000000000000000000000000000` (LEGACY_ETH_ADDRESS)
   *    or   `0x0000000000000000000000000000000000000001` (ETH_ADDRESS_IN_CONTRACTS)
   *  - ERC20: actual L1 token address */
  tokenL1Address: string;

  /** Amount to deposit (in token's smallest unit, i.e. wei for ETH) */
  amount: BigNumber;

  /** Recipient address on L2 */
  to: string;

  /**
   * Optional: caller/sender address on L1.
   * Affects gas estimation (storage slot aggregation). Defaults to a random address
   * (same behaviour as zksync-ethers internals).
   */
  from?: string;

  /**
   * Optional: extra tip for the L2 operator (on top of baseCost).
   * Defaults to 0. Rarely needed.
   */
  operatorTip?: BigNumber;
}

// ─── Output ───────────────────────────────────────────────────────────────────

/**
 * The computed gas parameters, ready to be passed directly into `wallet.deposit()`.
 *
 * @example
 * const params = await getDepositGasParams(config, request);
 * await wallet.deposit({
 *   token:             request.tokenL1Address,
 *   amount:            request.amount,
 *   to:                request.to,
 *   l2GasLimit:        params.l2GasLimit,
 *   gasPerPubdataByte: params.gasPerPubdataByte,
 *   overrides:         params.overrides,
 * });
 */
export interface DepositGasParams {
  // ── Direct wallet.deposit() fields ──────────────────────────────────────────

  /** L2 gas budget for the priority tx.  Already scaled by 1.2× safety factor. */
  l2GasLimit: BigNumber;

  /**
   * L2 gas per pubdata byte.  Always 800 for L1→L2 deposits (REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT).
   * Changing this directly scales baseCost.
   */
  gasPerPubdataByte: number;

  /**
   * L1 transaction overrides.
   * Contains `value` (mintValue = baseCost + operatorTip + l2Value) so the
   * caller does NOT need to compute it separately.
   */
  overrides: {
    /** mintValue to send with the L1 tx.  Must match msg.value in the contract. */
    value: BigNumber;
    /**
     * Recommended L1 gas limit for the deposit call.
     * Based on measured P90 values with a 30% safety margin.
     * Can be overridden by the caller.
     */
    gasLimit: BigNumber;
  };

  // ── Breakdown (for logging / inspection) ────────────────────────────────────
  readonly _breakdown: {
    /** Raw l2GasLimit before the 1.2× scaling factor */
    l2GasLimitRaw: BigNumber;
    /** baseCost in wei (= bridgehub.l2TransactionBaseCost(...)) */
    baseCost: BigNumber;
    /** operatorTip in wei (default 0) */
    operatorTip: BigNumber;
    /** l2Value in wei (ETH delivered to recipient; 0 for ERC20 deposits) */
    l2Value: BigNumber;
    /** mintValue = baseCost + operatorTip + l2Value */
    mintValue: BigNumber;
    /** L1 gas price (wei) used for baseCost calculation */
    l1GasPrice: BigNumber;
    /** How l2GasLimit was determined */
    l2GasLimitSource: 'live-estimate' | 'safe-minimum';
    /** Deposit type */
    depositType: DepositType;
    /** Whether this token is the chain's base token */
    isBaseToken: boolean;
  };
}

// ─── Options ─────────────────────────────────────────────────────────────────

export interface GasParamsOptions {
  /**
   * Override l2GasLimit instead of estimating it.
   * Useful if you already know the value or want to use a fixed budget.
   */
  l2GasLimitOverride?: BigNumber;

  /**
   * Override gasPerPubdataByte.  Defaults to 800 (REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT).
   * Only change this if the chain explicitly requires a different value.
   */
  gasPerPubdataByteOverride?: number;

  /**
   * When live l2GasLimit estimation fails or is not possible (e.g. no L2 RPC),
   * fall back to the lab-measured safe minimum values.
   * Default: true.
   */
  fallbackToSafeMinimum?: boolean;

  /**
   * Multiplier applied to the raw estimated l2GasLimit before using it.
   * zksync-ethers uses 1.2× (12/10). Default: 1.2.
   */
  l2GasLimitScaleFactor?: number;

  /**
   * Override the recommended L1 gasLimit for the deposit tx itself.
   * If not set, uses lab-measured P90 values with 30% margin.
   */
  l1GasLimitOverride?: BigNumber;
}
