/**
 * prividium-test.ts
 *
 * End-to-end test script for ZKsync L1→L2 bridge deposits through the
 * Prividium authenticated RPC proxy.
 *
 * PRE-REQUISITES
 * ──────────────
 * 1. Start the prividium proxy (opens a browser auth flow once):
 *
 *      # local-prividium docker stack:
 *      npx prividium proxy \
 *        --rpc-url http://localhost:5050 \
 *        --user-panel-url http://localhost:3001
 *
 *      # live / testnet:
 *      npx prividium proxy \
 *        --rpc-url https://<your-prividium-rpc> \
 *        --user-panel-url https://<your-user-panel>
 *
 *    The proxy then listens at http://127.0.0.1:24101/rpc — all requests are
 *    forwarded with your JWT token injected automatically.
 *
 * 2. Install script dependencies (once):
 *      npm install ethers@5 zksync-ethers tsx
 *
 * RUNNING
 * ───────
 *    SCENARIO=preview  npx tsx scripts/prividium-test.ts
 *    SCENARIO=discover npx tsx scripts/prividium-test.ts
 *    SCENARIO=eth-deposit    npx tsx scripts/prividium-test.ts
 *    SCENARIO=erc20-deposit  npx tsx scripts/prividium-test.ts
 *    SCENARIO=balance        npx tsx scripts/prividium-test.ts
 *
 *    PROFILE=live PRIVATE_KEY=0x... SCENARIO=preview npx tsx scripts/prividium-test.ts
 */

import { BigNumber, Contract, ethers } from 'ethers';
import { Provider as ZkProvider, Wallet as ZkWallet, utils as zkUtils } from 'zksync-ethers';

// ═════════════════════════════════════════════════════════════════════════════
//  CONFIGURATION — edit the sections below before running
// ═════════════════════════════════════════════════════════════════════════════

// Select profile via PROFILE env var (default: 'local').
const PROFILE = (process.env.PROFILE ?? 'local') as keyof typeof PROFILES;

// Select scenario via SCENARIO env var (default: 'preview').
const SCENARIO = (process.env.SCENARIO ?? 'preview') as Scenario;

// ── Profiles ──────────────────────────────────────────────────────────────────
//
// The L2 RPC is always the prividium proxy (http://127.0.0.1:24101/rpc).
// What changes between profiles is L1 provider, chain ID, and contract addresses.

const PROFILES = {

  // ── local-prividium docker stack ──────────────────────────────────────────
  local: {
    l2ChainId: 270,                            // default ZKsync OS chain id in local-prividium
    l1RpcUrl:  'http://localhost:5010',         // Anvil L1 from local-prividium
    l2RpcUrl:  'http://127.0.0.1:24101/rpc',   // prividium proxy → http://localhost:5050

    // Fill these from `SCENARIO=discover` output or docker-compose env vars.
    // The values below are typical for a fresh local-prividium deployment.
    bridgehubAddress:          '',  // ← run SCENARIO=discover to get this
    assetRouterL1Address:      '',  // ← L1AssetRouter / L1SharedBridge
    nativeTokenVaultL1Address: '',  // ← L1NTV
    baseTokenL1Address:        '0x0000000000000000000000000000000000000001',

    // Hardhat/Anvil rich account — safe to hardcode for local testing only.
    privateKey: '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',

    // Optional: ERC20 token on L1 to use for erc20-deposit scenario.
    erc20TokenL1Address: '',       // ← deploy a test token or fill from local-prividium

    // Deposit amount for ETH scenario.
    ethDepositAmount: ethers.utils.parseEther('0.01'),

    // Deposit amount for ERC20 scenario (in token's smallest unit).
    erc20DepositAmount: BigNumber.from('1000000'), // 1 USDC-like (6 decimals)
  },

  // ── Live / testnet ─────────────────────────────────────────────────────────
  live: {
    l2ChainId: 300,                            // ZKsync Sepolia testnet (use 324 for mainnet)
    l1RpcUrl:  process.env.L1_RPC_URL ?? 'https://rpc.ankr.com/eth_sepolia',
    l2RpcUrl:  'http://127.0.0.1:24101/rpc',   // same proxy, different upstream

    // ZKsync Sepolia contract addresses (update for mainnet if l2ChainId=324).
    bridgehubAddress:          '0x35A54c8C757806eB6820629bc82d90E056394C92',
    assetRouterL1Address:      '0x3E8b2fe58675126ed30d0d12dea2A9bda72D18Ae',
    nativeTokenVaultL1Address: '0x629b63Da608D0bE640a31B56ef7893A2BF223573',
    baseTokenL1Address:        '0x0000000000000000000000000000000000000001',

    // NEVER hardcode a real private key — always use env var.
    privateKey: process.env.PRIVATE_KEY ?? (() => { throw new Error('Set PRIVATE_KEY env var'); })(),

    erc20TokenL1Address: process.env.ERC20_TOKEN_L1 ?? '',
    ethDepositAmount:    ethers.utils.parseEther(process.env.ETH_AMOUNT ?? '0.001'),
    erc20DepositAmount:  BigNumber.from(process.env.ERC20_AMOUNT ?? '1000000'),
  },

} as const;

// ─── Types ─────────────────────────────────────────────────────────────────────

type Scenario = 'discover' | 'preview' | 'eth-deposit' | 'erc20-deposit' | 'balance';

// ═════════════════════════════════════════════════════════════════════════════
//  GAS PARAMETER LOGIC
//  (mirrors zksync-ethers adapters.ts + scaleGasLimit internals)
// ═════════════════════════════════════════════════════════════════════════════

const REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT = 800;
const SCALE_NUM = 12;
const SCALE_DEN = 10;

// Safe fallback values from lab measurements (bridge-gas-lab ANALYSIS.md).
const SAFE_L2_GAS = {
  'eth-base':      { recommended: BigNumber.from(90_000) },
  'erc20-nonbase': { recommended: BigNumber.from(300_000) },
};

const RECOMMENDED_L1_GAS = {
  'eth-base':      BigNumber.from(370_000),
  'erc20-nonbase': BigNumber.from(665_000),
};

const BRIDGEHUB_ABI = [
  'function l2TransactionBaseCost(uint256,uint256,uint256,uint256) external view returns (uint256)',
];

interface GasParams {
  l2GasLimit:        BigNumber;
  gasPerPubdataByte: number;
  overrides: { value: BigNumber; gasLimit: BigNumber };
  breakdown: {
    l2GasLimitRaw:    BigNumber;
    baseCost:         BigNumber;
    mintValue:        BigNumber;
    l1GasPrice:       BigNumber;
    l2GasLimitSource: 'live-estimate' | 'safe-minimum';
  };
}

async function computeGasParams(opts: {
  depositType:     'eth-base' | 'erc20-nonbase';
  tokenL1Address:  string;
  amount:          BigNumber;
  to:              string;
  from?:           string;
  l2ChainId:       number;
  bridgehubAddress:     string;
  assetRouterL1Address: string;
  l1Provider:      ethers.providers.Provider;
  l2Provider:      ZkProvider;
  l2GasLimitOverride?: BigNumber;
}): Promise<GasParams> {
  const gasPerPubdataByte = REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;

  // 1. L1 gas price (prefer EIP-1559 maxFeePerGas)
  const feeData  = await opts.l1Provider.getFeeData();
  const l1GasPrice = feeData.maxFeePerGas ?? feeData.gasPrice ?? BigNumber.from(0);

  // 2. Estimate l2GasLimit (mirrors _getL2GasLimit in zksync-ethers adapters.ts)
  let l2GasLimitRaw: BigNumber;
  let l2GasLimitSource: 'live-estimate' | 'safe-minimum';

  if (opts.l2GasLimitOverride) {
    l2GasLimitRaw   = opts.l2GasLimitOverride;
    l2GasLimitSource = 'live-estimate';
  } else {
    try {
      if (opts.depositType === 'eth-base') {
        l2GasLimitRaw = await opts.l2Provider.estimateL1ToL2Execute({
          contractAddress:   opts.to,
          gasPerPubdataByte,
          caller:            opts.from ?? ethers.Wallet.createRandom().address,
          calldata:          '0x',
          l2Value:           opts.amount,
        });
      } else {
        const bridgeAddresses = await opts.l2Provider.getDefaultBridgeAddresses();
        const bridgeData = await zkUtils.getERC20DefaultBridgeData(
          opts.tokenL1Address, opts.l1Provider
        );
        l2GasLimitRaw = await zkUtils.estimateCustomBridgeDepositL2Gas(
          opts.l2Provider,
          opts.assetRouterL1Address,
          bridgeAddresses.sharedL2,
          opts.tokenL1Address,
          opts.amount,
          opts.to,
          bridgeData,
          opts.from ?? ethers.Wallet.createRandom().address,
          gasPerPubdataByte,
          0,
        );
      }
      l2GasLimitSource = 'live-estimate';
    } catch (err) {
      console.warn(`  ⚠  L2 gas estimation failed (${(err as Error).message.slice(0, 80)})`);
      console.warn('     Falling back to lab-measured safe minimum.');
      l2GasLimitRaw   = SAFE_L2_GAS[opts.depositType].recommended;
      l2GasLimitSource = 'safe-minimum';
    }
  }

  // 3. Scale by 1.2× (mirrors zksync-ethers scaleGasLimit)
  const l2GasLimit = l2GasLimitRaw.mul(SCALE_NUM).div(SCALE_DEN);

  // 4. baseCost from Bridgehub
  const bridgehub = new Contract(opts.bridgehubAddress, BRIDGEHUB_ABI, opts.l1Provider);
  const baseCost: BigNumber = await bridgehub.l2TransactionBaseCost(
    opts.l2ChainId, l1GasPrice, l2GasLimit, gasPerPubdataByte
  );

  // 5. mintValue: baseCost + l2Value (0 for ERC20)
  const l2Value  = opts.depositType === 'eth-base' ? opts.amount : BigNumber.from(0);
  const mintValue = baseCost.add(l2Value);

  return {
    l2GasLimit,
    gasPerPubdataByte,
    overrides: {
      value:    mintValue,
      gasLimit: RECOMMENDED_L1_GAS[opts.depositType],
    },
    breakdown: { l2GasLimitRaw, baseCost, mintValue, l1GasPrice, l2GasLimitSource },
  };
}

// ═════════════════════════════════════════════════════════════════════════════
//  SCENARIOS
// ═════════════════════════════════════════════════════════════════════════════

async function scenarioDiscover(
  l1Provider: ethers.providers.Provider,
  l2Provider: ZkProvider,
) {
  console.log('\n── discover ─────────────────────────────────────────────────────');

  const [l1Network, l2Network] = await Promise.all([
    l1Provider.getNetwork(),
    l2Provider.getNetwork(),
  ]);
  console.log(`L1 chainId : ${l1Network.chainId}`);
  console.log(`L2 chainId : ${l2Network.chainId}`);

  const bridgeAddrs = await l2Provider.getDefaultBridgeAddresses();
  console.log(`L2 sharedBridge  : ${bridgeAddrs.sharedL2}`);
  console.log(`L1 sharedBridge  : ${bridgeAddrs.sharedL1}`);

  const mainContract = await l2Provider.getMainContractAddress();
  console.log(`L2 main contract : ${mainContract}`);

  const bridgehubAddr = await l2Provider.getBridgehubContractAddress();
  console.log(`Bridgehub (L1)   : ${bridgehubAddr}`);

  const baseToken = await l2Provider.getBaseTokenContractAddress();
  console.log(`Base token (L1)  : ${baseToken}`);

  console.log('\n→ Copy the above into the PROFILES section of this script.');
}

async function scenarioPreview(
  config: (typeof PROFILES)[typeof PROFILE],
  l1Provider: ethers.providers.Provider,
  l2Provider: ZkProvider,
  wallet:     ZkWallet,
) {
  console.log('\n── preview (read-only, no tx sent) ──────────────────────────────');

  const to = await wallet.getAddress();

  for (const depositType of ['eth-base', 'erc20-nonbase'] as const) {
    if (depositType === 'erc20-nonbase' && !config.erc20TokenL1Address) {
      console.log('\nerc20-nonbase: skipped (erc20TokenL1Address not set)');
      continue;
    }

    const tokenL1Address = depositType === 'eth-base'
      ? zkUtils.ETH_ADDRESS
      : config.erc20TokenL1Address;
    const amount = depositType === 'eth-base'
      ? config.ethDepositAmount
      : config.erc20DepositAmount;

    console.log(`\n[${depositType}]`);
    const params = await computeGasParams({
      depositType,
      tokenL1Address,
      amount,
      to,
      from: to,
      l2ChainId:            config.l2ChainId,
      bridgehubAddress:     config.bridgehubAddress,
      assetRouterL1Address: config.assetRouterL1Address,
      l1Provider,
      l2Provider,
    });

    printParams(params, amount, depositType);
  }
}

async function scenarioEthDeposit(
  config: (typeof PROFILES)[typeof PROFILE],
  l1Provider: ethers.providers.Provider,
  l2Provider: ZkProvider,
  wallet:     ZkWallet,
) {
  console.log('\n── eth-deposit ──────────────────────────────────────────────────');

  const to     = await wallet.getAddress();
  const amount = config.ethDepositAmount;

  const params = await computeGasParams({
    depositType:          'eth-base',
    tokenL1Address:       zkUtils.ETH_ADDRESS,
    amount,
    to,
    from:                 to,
    l2ChainId:            config.l2ChainId,
    bridgehubAddress:     config.bridgehubAddress,
    assetRouterL1Address: config.assetRouterL1Address,
    l1Provider,
    l2Provider,
  });

  printParams(params, amount, 'eth-base');

  console.log('\nSending deposit…');
  const tx = await wallet.deposit({
    token:             zkUtils.ETH_ADDRESS,
    amount,
    to,
    l2GasLimit:        params.l2GasLimit,
    gasPerPubdataByte: params.gasPerPubdataByte,
    overrides:         params.overrides,
  });

  console.log(`L1 tx hash : ${tx.hash}`);
  console.log('Waiting for L2 receipt…');
  const receipt = await tx.waitFinalize();
  console.log(`L2 receipt : block ${receipt.blockNumber}  status ${receipt.status === 1 ? 'SUCCESS' : 'FAILED'}`);
}

async function scenarioERC20Deposit(
  config: (typeof PROFILES)[typeof PROFILE],
  l1Provider: ethers.providers.Provider,
  l2Provider: ZkProvider,
  wallet:     ZkWallet,
) {
  console.log('\n── erc20-deposit ────────────────────────────────────────────────');

  if (!config.erc20TokenL1Address) {
    console.error('ERROR: erc20TokenL1Address is not set in the profile.');
    process.exit(1);
  }

  const to     = await wallet.getAddress();
  const amount = config.erc20DepositAmount;
  const token  = config.erc20TokenL1Address;

  const params = await computeGasParams({
    depositType:          'erc20-nonbase',
    tokenL1Address:       token,
    amount,
    to,
    from:                 to,
    l2ChainId:            config.l2ChainId,
    bridgehubAddress:     config.bridgehubAddress,
    assetRouterL1Address: config.assetRouterL1Address,
    l1Provider,
    l2Provider,
  });

  printParams(params, amount, 'erc20-nonbase');

  console.log('\nSending deposit (approveERC20=true)…');
  const tx = await wallet.deposit({
    token,
    amount,
    to,
    approveERC20:      true,
    l2GasLimit:        params.l2GasLimit,
    gasPerPubdataByte: params.gasPerPubdataByte,
    overrides:         params.overrides,
  });

  console.log(`L1 tx hash : ${tx.hash}`);
  console.log('Waiting for L2 receipt…');
  const receipt = await tx.waitFinalize();
  console.log(`L2 receipt : block ${receipt.blockNumber}  status ${receipt.status === 1 ? 'SUCCESS' : 'FAILED'}`);
}

async function scenarioBalance(
  l1Provider: ethers.providers.Provider,
  l2Provider: ZkProvider,
  wallet:     ZkWallet,
) {
  console.log('\n── balance ──────────────────────────────────────────────────────');

  const addr = await wallet.getAddress();
  const [l1Eth, l2Eth] = await Promise.all([
    l1Provider.getBalance(addr),
    l2Provider.getBalance(addr),
  ]);

  console.log(`Address   : ${addr}`);
  console.log(`L1 ETH    : ${ethers.utils.formatEther(l1Eth)} ETH`);
  console.log(`L2 ETH    : ${ethers.utils.formatEther(l2Eth)} ETH`);
}

// ═════════════════════════════════════════════════════════════════════════════
//  HELPERS
// ═════════════════════════════════════════════════════════════════════════════

function printParams(
  p: GasParams,
  depositAmount: BigNumber,
  depositType: 'eth-base' | 'erc20-nonbase',
) {
  const fmt = (v: BigNumber) => ethers.utils.formatEther(v);
  const gwei = (v: BigNumber) => ethers.utils.formatUnits(v, 'gwei');

  console.log(`  l2GasLimit       : ${p.l2GasLimit.toString()}  (raw ${p.breakdown.l2GasLimitRaw.toString()} × 1.2)  [${p.breakdown.l2GasLimitSource}]`);
  console.log(`  gasPerPubdata    : ${p.gasPerPubdataByte}`);
  console.log(`  l1GasPrice       : ${gwei(p.breakdown.l1GasPrice)} gwei`);
  console.log(`  baseCost         : ${fmt(p.breakdown.baseCost)} ETH`);
  if (depositType === 'eth-base') {
    console.log(`  l2Value (ETH)    : ${fmt(depositAmount)} ETH`);
  }
  console.log(`  mintValue (msg.value) : ${fmt(p.breakdown.mintValue)} ETH`);
  console.log(`  L1 gasLimit      : ${p.overrides.gasLimit.toString()}`);
}

// ═════════════════════════════════════════════════════════════════════════════
//  MAIN
// ═════════════════════════════════════════════════════════════════════════════

async function main() {
  const config = PROFILES[PROFILE];
  if (!config) {
    console.error(`Unknown PROFILE="${PROFILE}". Valid: ${Object.keys(PROFILES).join(', ')}`);
    process.exit(1);
  }

  console.log(`Profile  : ${PROFILE}`);
  console.log(`Scenario : ${SCENARIO}`);
  console.log(`L1 RPC   : ${config.l1RpcUrl}`);
  console.log(`L2 RPC   : ${config.l2RpcUrl}  (prividium proxy)`);

  const l1Provider = new ethers.providers.JsonRpcProvider(config.l1RpcUrl);
  const l2Provider = new ZkProvider(config.l2RpcUrl);
  // ZkWallet wraps both L1 and L2: L1 for signing deposits, L2 (proxy) for state queries.
  const wallet     = new ZkWallet(config.privateKey, l2Provider, l1Provider);

  if (SCENARIO !== 'discover') {
    if (!config.bridgehubAddress) {
      console.error('ERROR: bridgehubAddress is empty. Run SCENARIO=discover first.');
      process.exit(1);
    }
  }

  switch (SCENARIO) {
    case 'discover':
      await scenarioDiscover(l1Provider, l2Provider);
      break;
    case 'preview':
      await scenarioPreview(config, l1Provider, l2Provider, wallet);
      break;
    case 'eth-deposit':
      await scenarioEthDeposit(config, l1Provider, l2Provider, wallet);
      break;
    case 'erc20-deposit':
      await scenarioERC20Deposit(config, l1Provider, l2Provider, wallet);
      break;
    case 'balance':
      await scenarioBalance(l1Provider, l2Provider, wallet);
      break;
    default:
      console.error(`Unknown SCENARIO="${SCENARIO}". Valid: discover, preview, eth-deposit, erc20-deposit, balance`);
      process.exit(1);
  }
}

main().catch(err => {
  console.error('\nFATAL:', err.message ?? err);
  process.exit(1);
});
