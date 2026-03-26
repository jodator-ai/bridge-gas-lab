/**
 * Example: how to wire getDepositGasParams into existing zksync-ethers deposit code.
 *
 * Pattern 1 — drop-in replacement for manual gas computation
 * Pattern 2 — inspect params before committing
 * Pattern 3 — custom l2GasLimit override (e.g. from lab measurements)
 */

import * as ethers from 'ethers';
import { Provider as ZkProvider, Wallet, utils } from 'zksync-ethers';
import { getDepositGasParams } from './gas-params';
import type { ChainConfig } from './types';

// ─── Chain config (fill from your deployment / discovery) ────────────────────

const CHAIN_CONFIG: ChainConfig = {
  l2ChainId: 324,                                              // ZKsync Era mainnet
  bridgehubAddress:         '0x303a465B659cBB0ab36eE643eA362c509EEb5213',
  assetRouterL1Address:     '0x2E021a37588462F1A309a274ee7243027173aEB5', // L1AssetRouter
  nativeTokenVaultL1Address:'0x0124f62abcd7f37a34f8b322b1b0583726de52d4', // L1NTV
  baseTokenL1Address:       '0x0000000000000000000000000000000000000001', // ETH-based chain
  l1Provider: new ethers.providers.JsonRpcProvider('https://eth.llamarpc.com'),
  l2Provider: new ZkProvider('https://mainnet.era.zksync.io'),
};

// ─── Pattern 1: ETH deposit — minimal code ────────────────────────────────────

async function depositEth(wallet: Wallet, to: string, amountEth: string) {
  const amount = ethers.utils.parseEther(amountEth);

  const params = await getDepositGasParams(CHAIN_CONFIG, {
    type: 'eth-base',
    tokenL1Address: utils.ETH_ADDRESS,
    amount,
    to,
  });

  console.log('Gas params:', {
    l2GasLimit:        params.l2GasLimit.toString(),
    gasPerPubdataByte: params.gasPerPubdataByte,
    mintValue:         ethers.utils.formatEther(params.overrides.value) + ' ETH',
    baseCost:          ethers.utils.formatEther(params._breakdown.baseCost) + ' ETH',
    l2GasLimitSource:  params._breakdown.l2GasLimitSource,
  });

  const tx = await wallet.deposit({
    token:             utils.ETH_ADDRESS,
    amount,
    to,
    l2GasLimit:        params.l2GasLimit,
    gasPerPubdataByte: params.gasPerPubdataByte,
    overrides:         params.overrides,
  });

  console.log('Deposit tx:', tx.hash);
  await tx.waitFinalize();
}

// ─── Pattern 2: ERC20 deposit — first time vs subsequent ─────────────────────

async function depositERC20(
  wallet: Wallet,
  tokenL1Address: string,
  to: string,
  amount: ethers.BigNumber,
  isFirstDeposit: boolean,
) {
  const params = await getDepositGasParams(
    CHAIN_CONFIG,
    {
      type: 'erc20-nonbase',
      tokenL1Address,
      amount,
      to,
      from: await wallet.getAddress(),  // improves gas estimate accuracy
    },
    {
      // For first-ever deposit, bump l2GasLimit to cover L2 token contract deployment
      l2GasLimitOverride: isFirstDeposit
        ? ethers.BigNumber.from(250_000)  // from SAFE_L2_GAS_LIMITS['erc20-nonbase'].firstDeposit
        : undefined,
    }
  );

  const tx = await wallet.deposit({
    token:             tokenL1Address,
    amount,
    to,
    approveERC20:      true,             // zksync-ethers handles the ERC20 approval
    l2GasLimit:        params.l2GasLimit,
    gasPerPubdataByte: params.gasPerPubdataByte,
    overrides:         params.overrides,
  });

  return tx;
}

// ─── Pattern 3: Use lab-measured values (no L2 provider needed) ──────────────

async function depositEthOffline(wallet: Wallet, to: string, amountEth: string) {
  const amount = ethers.utils.parseEther(amountEth);

  const params = await getDepositGasParams(
    CHAIN_CONFIG,
    { type: 'eth-base', tokenL1Address: utils.ETH_ADDRESS, amount, to },
    {
      l2GasLimitOverride:  ethers.BigNumber.from(90_000),  // lab-measured minimum × 1.2
      fallbackToSafeMinimum: true,                         // use safe values if estimate fails
    }
  );

  const tx = await wallet.deposit({
    token: utils.ETH_ADDRESS,
    amount,
    to,
    l2GasLimit:        params.l2GasLimit,
    gasPerPubdataByte: params.gasPerPubdataByte,
    overrides:         params.overrides,
  });

  return tx;
}

// ─── Pattern 4: Inspect without sending (fee preview) ─────────────────────────

async function previewDepositFees(tokenL1Address: string, amountRaw: string, to: string) {
  const isEth = tokenL1Address === utils.ETH_ADDRESS ||
                tokenL1Address === ethers.constants.AddressZero;

  const amount = ethers.BigNumber.from(amountRaw);
  const params = await getDepositGasParams(CHAIN_CONFIG, {
    type: isEth ? 'eth-base' : 'erc20-nonbase',
    tokenL1Address,
    amount,
    to,
  });

  const { baseCost, mintValue, l2GasLimitRaw, l2GasLimit, l1GasPrice } = params._breakdown;
  const feeData = await CHAIN_CONFIG.l1Provider.getFeeData();
  const l1GasLimitForTx = params.overrides.gasLimit;

  return {
    baseCostEth:      ethers.utils.formatEther(baseCost),
    mintValueEth:     ethers.utils.formatEther(mintValue),
    estimatedL1Fee:   ethers.utils.formatEther(
                        l1GasLimitForTx.mul(feeData.maxFeePerGas ?? l1GasPrice)
                      ),
    l2GasLimitRaw:    l2GasLimitRaw.toString(),
    l2GasLimit:       l2GasLimit.toString(),          // after 1.2× scaling
    gasPerPubdata:    params.gasPerPubdataByte,
    l1GasPriceGwei:   ethers.utils.formatUnits(l1GasPrice, 'gwei'),
    source:           params._breakdown.l2GasLimitSource,
  };
}

export { depositEth, depositERC20, depositEthOffline, previewDepositFees };
