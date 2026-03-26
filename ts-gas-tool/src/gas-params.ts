/**
 * ZKsync L1→L2 Bridge Gas Parameters
 *
 * Computes all gas-related parameters needed for wallet.deposit() calls
 * using the zksync-ethers library, based on on-chain baseCost queries and
 * either live L2 gas estimation or lab-measured safe minimum values.
 *
 * Usage:
 *   const params = await getDepositGasParams(chainConfig, depositRequest, options);
 *   await wallet.deposit({
 *     token: request.tokenL1Address,
 *     amount: request.amount,
 *     to: request.to,
 *     ...params,        // spreads l2GasLimit, gasPerPubdataByte, overrides
 *   });
 */

import { BigNumber, Contract, ethers } from 'ethers';
import {
  utils as zkUtils,
  // These match adapters.ts _getL2GasLimit internals exactly:
} from 'zksync-ethers';
import type { ChainConfig, DepositRequest, DepositGasParams, GasParamsOptions } from './types';
import {
  REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
  ETH_ADDRESS_IN_CONTRACTS,
  LEGACY_ETH_ADDRESS,
  L2_GAS_LIMIT_SCALE_NUMERATOR,
  L2_GAS_LIMIT_SCALE_DENOMINATOR,
  SAFE_L2_GAS_LIMITS,
  RECOMMENDED_L1_GAS_LIMITS,
} from './constants';

// ─── Minimal ABI (no full artifact needed) ────────────────────────────────────

const BRIDGEHUB_ABI = [
  'function l2TransactionBaseCost(uint256 _chainId, uint256 _gasPrice, uint256 _l2GasLimit, uint256 _l2GasPerPubdataByteLimit) external view returns (uint256)',
] as const;

// ─── Public API ───────────────────────────────────────────────────────────────

/**
 * Compute all gas parameters needed for a ZKsync L1→L2 bridge deposit.
 *
 * @param config   - Static chain configuration (addresses, providers)
 * @param request  - What to deposit (type, token, amount, recipient)
 * @param options  - Optional overrides and behaviour flags
 * @returns        - Gas params ready to spread into `wallet.deposit()`
 *
 * @example
 * // ETH deposit on an ETH-based chain
 * const params = await getDepositGasParams(
 *   { l2ChainId: 324, bridgehubAddress: '0x...', ..., l1Provider, l2Provider },
 *   { type: 'eth-base', tokenL1Address: ethers.constants.AddressZero,
 *     amount: ethers.utils.parseEther('0.01'), to: recipientAddress },
 * );
 * await wallet.deposit({
 *   token:             utils.ETH_ADDRESS,
 *   amount:            request.amount,
 *   to:                request.to,
 *   l2GasLimit:        params.l2GasLimit,
 *   gasPerPubdataByte: params.gasPerPubdataByte,
 *   overrides:         params.overrides,
 * });
 *
 * @example
 * // ERC20 non-base deposit
 * const params = await getDepositGasParams(config,
 *   { type: 'erc20-nonbase', tokenL1Address: usdcL1Address,
 *     amount: BigNumber.from('1000000'), to: recipientAddress },
 * );
 * await wallet.deposit({
 *   token: usdcL1Address, amount: request.amount, to: request.to, ...params
 * });
 */
export async function getDepositGasParams(
  config: ChainConfig,
  request: DepositRequest,
  options: GasParamsOptions = {}
): Promise<DepositGasParams> {
  const {
    l2GasLimitOverride,
    gasPerPubdataByteOverride,
    fallbackToSafeMinimum = true,
    l2GasLimitScaleFactor = L2_GAS_LIMIT_SCALE_NUMERATOR / L2_GAS_LIMIT_SCALE_DENOMINATOR,
    l1GasLimitOverride,
  } = options;

  const gasPerPubdataByte = gasPerPubdataByteOverride ?? REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;
  const operatorTip = request.operatorTip ?? BigNumber.from(0);
  const isBaseToken = _isBaseToken(request.tokenL1Address, config.baseTokenL1Address);

  // ── 1. Current L1 gas price (EIP-1559 or legacy) ──────────────────────────
  //
  // zksync-ethers adapters.ts insertGasPrice() uses maxFeePerGas when available.
  // baseCost scales linearly with gas price — always use a fresh value.
  const l1GasPrice = await _getL1GasPrice(config.l1Provider);

  // ── 2. Estimate or override l2GasLimit ────────────────────────────────────
  //
  // zksync-ethers _getDepositTxWithDefaults():
  //   tx.l2GasLimit ??= await this._getL2GasLimit(tx)
  //
  // We mirror the same decision tree:
  //   - base token deposit → estimateL1ToL2Execute (simple balance credit on L2)
  //   - ERC20 non-base    → estimateCustomBridgeDepositL2Gas (calls L2 NTV.bridgeMint)
  let l2GasLimitRaw: BigNumber;
  let l2GasLimitSource: 'live-estimate' | 'safe-minimum';

  if (l2GasLimitOverride) {
    l2GasLimitRaw = l2GasLimitOverride;
    l2GasLimitSource = 'live-estimate';
  } else {
    const estimated = await _estimateL2GasLimit(
      config, request, gasPerPubdataByte, fallbackToSafeMinimum
    );
    l2GasLimitRaw = estimated.gasLimit;
    l2GasLimitSource = estimated.source;
  }

  // ── 3. Apply 1.2× safety scale factor ────────────────────────────────────
  //
  // zksync-ethers scaleGasLimit():
  //   gasLimit.mul(L1_FEE_ESTIMATION_COEF_NUMERATOR).div(L1_FEE_ESTIMATION_COEF_DENOMINATOR)
  //   = gasLimit × 12 / 10
  const l2GasLimit = _scaleGasLimit(l2GasLimitRaw, l2GasLimitScaleFactor);

  // ── 4. baseCost = Bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2Gas, perPubdata)
  const baseCost = await _getBaseCost(config, l1GasPrice, l2GasLimit, gasPerPubdataByte);

  // ── 5. mintValue computation ──────────────────────────────────────────────
  //
  // zksync-ethers adapters.ts (requestL2TransactionDirect path ~line 807):
  //   For base token: mintValue = baseCost + operatorTip + amount
  //   For non-base:   mintValue = baseCost + operatorTip           (ERC20 handled by NTV)
  //
  // msg.value sent with the L1 tx MUST equal mintValue exactly.
  const l2Value = isBaseToken ? request.amount : BigNumber.from(0);
  const mintValue = baseCost.add(operatorTip).add(l2Value);

  // ── 6. Recommended L1 gasLimit for the deposit call ──────────────────────
  const l1GasLimit = l1GasLimitOverride ?? RECOMMENDED_L1_GAS_LIMITS[request.type];

  return {
    l2GasLimit,
    gasPerPubdataByte,
    overrides: {
      value:    mintValue,
      gasLimit: l1GasLimit,
    },
    _breakdown: {
      l2GasLimitRaw,
      baseCost,
      operatorTip,
      l2Value,
      mintValue,
      l1GasPrice,
      l2GasLimitSource,
      depositType: request.type,
      isBaseToken,
    },
  };
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

/**
 * Get current L1 gas price for baseCost calculation.
 * Uses maxFeePerGas (EIP-1559) when available, falls back to legacy gasPrice.
 *
 * Note: on high-activity networks the actual gas price may exceed this estimate
 * by the time the tx is included. zksync-ethers handles this via overrides.gasPrice.
 */
async function _getL1GasPrice(l1Provider: ethers.providers.Provider): Promise<BigNumber> {
  const feeData = await l1Provider.getFeeData();
  return feeData.maxFeePerGas ?? feeData.gasPrice ?? BigNumber.from(0);
}

/**
 * Query Bridgehub.l2TransactionBaseCost() — the authoritative source for fee computation.
 *
 * From zksync-ethers adapters.ts getBaseCost() (IBridgehub 4-param variant):
 *   bridgehub.l2TransactionBaseCost(chainId, gasPriceForEstimation, l2GasLimit, gasPerPubdataByte)
 *
 * The formula implemented in the diamond proxy roughly approximates:
 *   baseCost ≈ l2GasLimit × 262_500 × l1GasPrice  (at gasPerPubdata=800)
 * Verified empirically against ZKsync OS v0.18.0 in bridge-gas-lab measurements.
 */
async function _getBaseCost(
  config: ChainConfig,
  l1GasPrice: BigNumber,
  l2GasLimit: BigNumber,
  gasPerPubdataByte: number
): Promise<BigNumber> {
  const bridgehub = new Contract(config.bridgehubAddress, BRIDGEHUB_ABI, config.l1Provider);
  const baseCost: BigNumber = await bridgehub.l2TransactionBaseCost(
    config.l2ChainId,
    l1GasPrice,
    l2GasLimit,
    gasPerPubdataByte
  );
  return baseCost;
}

/**
 * Estimate L2 gas limit by mirroring zksync-ethers _getL2GasLimit() logic exactly.
 *
 * Base-token deposits (ETH on ETH chain):
 *   → providerL2.estimateL1ToL2Execute({ contractAddress: to, l2Value: amount, calldata: '0x' })
 *   Source: adapters.ts _getL2GasLimit → estimateDefaultBridgeDepositL2Gas (isBaseToken branch)
 *
 * ERC20 non-base deposits:
 *   → zkUtils.estimateCustomBridgeDepositL2Gas(providerL2, l1BridgeAddr, l2BridgeAddr, ...)
 *   Source: adapters.ts _getL2GasLimit → estimateDefaultBridgeDepositL2Gas (else branch)
 *   → calls L2 with caller = applyL1ToL2Alias(l1AssetRouter)
 *   → calldata = L2Bridge.finalizeDeposit(sender, receiver, token, amount, bridgeData)
 *   → bridgeData = abi.encode(nameBytes, symbolBytes, decimalsBytes)
 *
 * Falls back to lab-measured safe minimums on failure (default: true).
 */
async function _estimateL2GasLimit(
  config: ChainConfig,
  request: DepositRequest,
  gasPerPubdataByte: number,
  fallbackToSafeMinimum: boolean
): Promise<{ gasLimit: BigNumber; source: 'live-estimate' | 'safe-minimum' }> {
  try {
    let gasLimit: BigNumber;
    const from = request.from ?? ethers.Wallet.createRandom().address;

    if (request.type === 'eth-base' || request.type === 'erc20-base') {
      // Base-token: L2 execution just credits the balance — minimal gas.
      // zksync-ethers: estimateDefaultBridgeDepositL2Gas → providerL2.estimateL1ToL2Execute
      gasLimit = await config.l2Provider.estimateL1ToL2Execute({
        contractAddress: request.to,
        gasPerPubdataByte,
        caller: from,
        calldata: '0x',
        l2Value: request.amount,
      });
    } else {
      // ERC20 non-base: L2 executes NTV.bridgeMint → deploys or mints wrapped token.
      // Delegate entirely to zksync-ethers utils to match its exact calldata format.
      const bridgeAddresses = await config.l2Provider.getDefaultBridgeAddresses();

      // getERC20DefaultBridgeData fetches name/symbol/decimals from L1 token contract.
      // This is the bridgeData passed to L2 NTV to deploy/identify the wrapped token.
      const bridgeData = await zkUtils.getERC20DefaultBridgeData(
        request.tokenL1Address,
        config.l1Provider
      );

      gasLimit = await zkUtils.estimateCustomBridgeDepositL2Gas(
        config.l2Provider,
        config.assetRouterL1Address,   // l1BridgeAddress (L1AssetRouter)
        bridgeAddresses.sharedL2,      // l2BridgeAddress (L2AssetRouter)
        request.tokenL1Address,
        request.amount,
        request.to,
        bridgeData,
        from,
        gasPerPubdataByte,
        0 // l2Value = 0 for ERC20 deposits
      );
    }

    return { gasLimit, source: 'live-estimate' };
  } catch (err) {
    if (!fallbackToSafeMinimum) {
      throw new Error(
        `L2 gas estimation failed and fallbackToSafeMinimum=false.\n` +
        `Cause: ${(err as Error).message}\n\n` +
        `Tip: pass l2GasLimitOverride or set fallbackToSafeMinimum=true.`
      );
    }
    // Use lab-measured safe values from ANALYSIS.md recommendation matrix
    const safe = SAFE_L2_GAS_LIMITS[request.type];
    return { gasLimit: safe.recommended, source: 'safe-minimum' };
  }
}

/**
 * Apply a scale factor to a gas limit.
 * Mirrors zksync-ethers scaleGasLimit() (12/10 = 1.2×):
 *   gasLimit.mul(L1_FEE_ESTIMATION_COEF_NUMERATOR).div(L1_FEE_ESTIMATION_COEF_DENOMINATOR)
 *
 * @param gasLimit - raw estimated gas limit
 * @param factor   - multiplier (default 1.2)
 */
function _scaleGasLimit(gasLimit: BigNumber, factor: number): BigNumber {
  const numerator = Math.round(factor * 10);
  return gasLimit.mul(numerator).div(10);
}

/**
 * Determine if the deposit token is the chain's base token.
 *
 * Both LEGACY_ETH_ADDRESS (0x000...0) and ETH_ADDRESS_IN_CONTRACTS (0x000...1)
 * are treated as ETH (matching zksync-ethers utils.isETH()).
 *
 * For chains whose base token is an ERC20, `baseTokenL1Address` will be a real
 * contract address and only exact matches count.
 */
function _isBaseToken(tokenAddress: string, baseTokenL1Address: string): boolean {
  const norm = (a: string) => a.toLowerCase();
  const token = norm(tokenAddress);
  const base  = norm(baseTokenL1Address);

  const isEthSentinel = (a: string) =>
    a === norm(LEGACY_ETH_ADDRESS) || a === norm(ETH_ADDRESS_IN_CONTRACTS);

  return isEthSentinel(token) ? isEthSentinel(base) : token === base;
}
