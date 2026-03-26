import { BigNumber } from 'ethers';
import type { DepositType } from './types';

/**
 * L2 gas per pubdata byte for L1→L2 deposits.
 * From zksync-ethers utils.ts: REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT = 800
 * This is distinct from DEFAULT_GAS_PER_PUBDATA_LIMIT (50,000) used for L2-only txs.
 */
export const REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT = 800;

/**
 * ETH address as used in ZKsync bridge contracts.
 * The Bridgehub and NTV use this sentinel address to represent native ETH.
 */
export const ETH_ADDRESS_IN_CONTRACTS = '0x0000000000000000000000000000000000000001';

/**
 * Legacy ETH address (zero address) — also accepted as ETH by zksync-ethers.
 */
export const LEGACY_ETH_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * zksync-ethers scale factor for l2GasLimit (12/10 = 1.2×).
 * Applied to estimated gas to provide a safety buffer.
 * Source: L1_FEE_ESTIMATION_COEF_NUMERATOR / L1_FEE_ESTIMATION_COEF_DENOMINATOR
 */
export const L2_GAS_LIMIT_SCALE_NUMERATOR = 12;
export const L2_GAS_LIMIT_SCALE_DENOMINATOR = 10;

/**
 * Lab-measured safe minimum l2GasLimit values per deposit type.
 *
 * These are the MINIMUM values at which the L2 execution succeeds, based on
 * experiments with ZKsync OS v0.18.0, Calldata pubdata mode, gasPerPubdata=800.
 *
 * The recommended values include the 1.2× zksync-ethers safety factor.
 * Source: bridge-gas-lab ANALYSIS.md + results/raw/*.json
 */
export const SAFE_L2_GAS_LIMITS: Record<
  DepositType,
  { minimum: BigNumber; recommended: BigNumber; firstDeposit?: BigNumber }
> = {
  'eth-base': {
    // Binary-searched minimum confirmed at 71,875.
    // Recommended = ceil(71875 * 1.2) = 86,250 → round up to 90,000 for safety.
    minimum:     BigNumber.from(71_875),
    recommended: BigNumber.from(90_000),
  },
  'erc20-base': {
    // Same as eth-base when base token is ERC20 (rare). Conservative estimate.
    minimum:     BigNumber.from(71_875),
    recommended: BigNumber.from(90_000),
  },
  'erc20-nonbase': {
    // First-time deposit: L2 must deploy the wrapped token contract.
    // Subsequent deposits: token already exists on L2.
    // minimum not confirmed via binary search (static call fails on transferFrom).
    // firstDeposit recommended based on lab measurement (l2GasLimit=200K was observed to work).
    minimum:      BigNumber.from(200_000),
    recommended:  BigNumber.from(300_000),
    firstDeposit: BigNumber.from(250_000),  // extra budget for token deployment
  },
};

/**
 * Recommended L1 gasLimit for the deposit call itself, per deposit type.
 * Based on lab measurements: median P90 with 30% safety margin.
 *
 * These govern how much gas the L1 Ethereum tx is allowed to use (not the L2 execution).
 * Source: bridge-gas-lab ANALYSIS.md — Updated Recommendation Matrix (2026-03-26)
 */
export const RECOMMENDED_L1_GAS_LIMITS: Record<DepositType, BigNumber> = {
  // eth-base-eoa P90 ≈ 320K × 1.3 ≈ 370K (also covers contract recipients)
  'eth-base':    BigNumber.from(370_000),
  'erc20-base':  BigNumber.from(370_000),
  // erc20-nonbase-first P90 ≈ 511K × 1.3 ≈ 665K (conservative: always use first-deposit budget)
  'erc20-nonbase': BigNumber.from(665_000),
};
