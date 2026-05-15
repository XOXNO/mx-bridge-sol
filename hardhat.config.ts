import "dotenv/config";

import type { HardhatUserConfig } from "hardhat/config";
import { configVariable } from "hardhat/config";

import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import hardhatFoundry from "@nomicfoundation/hardhat-foundry";
import hardhatLedger from "@nomicfoundation/hardhat-ledger";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatUpgrades from "@openzeppelin/hardhat-upgrades";

import deployBridgeAdaptor from "./tasks/deploy/bridge-adaptor.js";
import forceImportBridgeAdaptor from "./tasks/deploy/force-import-bridge-adaptor.js";
import upgradeBridgeAdaptor from "./tasks/deploy/upgrade-bridge-adaptor.js";
import upgradeBridgeAdaptorToImplementation from "./tasks/deploy/upgrade-bridge-adaptor-to-implementation.js";
import validateBridgeAdaptorUpgrade from "./tasks/deploy/validate-bridge-adaptor-upgrade.js";
import verifyBridgeAdaptor from "./tasks/deploy/verify-bridge-adaptor.js";
import enableWormhole from "./tasks/adaptor/enable-wormhole.js";
import enableCctp from "./tasks/adaptor/enable-cctp.js";
import unpauseAdaptor from "./tasks/adaptor/unpause-adaptor.js";
import pauseAdaptor from "./tasks/adaptor/pause-adaptor.js";
import setCustomAdmin from "./tasks/adaptor/set-custom-admin.js";
import acceptAdmin from "./tasks/adaptor/accept-admin.js";
import cancelAdminTransfer from "./tasks/adaptor/cancel-admin-transfer.js";
import setCircleTransmitter from "./tasks/adaptor/set-circle-transmitter.js";
import updateWormholeContracts from "./tasks/adaptor/update-wormhole-contracts.js";
import depositCctpV2 from "./tasks/adaptor/deposit-cctp-v2.js";
import claimCctpV2ToAdmin from "./tasks/adaptor/claim-cctp-v2-to-admin.js";
import claimFees from "./tasks/adaptor/claim-fees.js";
import settleWormhole from "./tasks/adaptor/settle-wormhole.js";
import rescueCctp from "./tasks/adaptor/rescue-cctp.js";
import recoverTokens from "./tasks/adaptor/recover-tokens.js";
import fees from "./tasks/adaptor/fees.js";
import setFeeConfig from "./tasks/adaptor/set-fee-config.js";
import enableLayerZero from "./tasks/adaptor/enable-layerzero.js";
import setLayerZeroEndpoint from "./tasks/adaptor/set-layerzero-endpoint.js";
import setLayerZeroFee from "./tasks/adaptor/set-layerzero-fee.js";
import setLayerZeroOftToken from "./tasks/adaptor/set-layerzero-oft-token.js";
import setLayerZeroSource from "./tasks/adaptor/set-layerzero-source.js";
import rescueLayerZero from "./tasks/adaptor/rescue-layerzero.js";

const initialIndex = Number(process.env.INITIAL_INDEX ?? 0);

const solcSettings = {
  metadata: { bytecodeHash: "none" as const },
  optimizer: { enabled: true, runs: 200 },
  outputSelection: { "*": { "*": ["storageLayout"] } },
};

const config: HardhatUserConfig = {
  plugins: [hardhatToolboxMochaEthers, hardhatFoundry, hardhatLedger, hardhatVerify, hardhatUpgrades],
  verify: {
    etherscan: {
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
  },
  tasks: [
    deployBridgeAdaptor,
    forceImportBridgeAdaptor,
    upgradeBridgeAdaptor,
    upgradeBridgeAdaptorToImplementation,
    validateBridgeAdaptorUpgrade,
    verifyBridgeAdaptor,
    enableWormhole,
    enableCctp,
    pauseAdaptor,
    unpauseAdaptor,
    setCustomAdmin,
    acceptAdmin,
    cancelAdminTransfer,
    setCircleTransmitter,
    updateWormholeContracts,
    depositCctpV2,
    claimCctpV2ToAdmin,
    claimFees,
    settleWormhole,
    rescueCctp,
    recoverTokens,
    fees,
    setFeeConfig,
    enableLayerZero,
    setLayerZeroEndpoint,
    setLayerZeroFee,
    setLayerZeroOftToken,
    setLayerZeroSource,
    rescueLayerZero,
  ],
  solidity: {
    profiles: {
      default: {
        compilers: [{ version: "0.8.35", settings: solcSettings }],
      },
    },
  },
  paths: {
    artifacts: "./artifacts",
    cache: "./cache",
    sources: "./contracts",
    tests: "./test",
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
      accounts: {
        mnemonic: configVariable("MNEMONIC"),
      },
    },
    mainnet_eth: {
      type: "http",
      chainType: "l1",
      // Prefer MAINNET_RPC_URL (the same endpoint fork tests use, typically Alchemy);
      // fall back to Infura when only INFURA_API_KEY is set.
      url: process.env.MAINNET_RPC_URL || `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY ?? ""}`,
      accounts: {
        mnemonic: configVariable("MNEMONIC"),
        count: 12,
        path: "m/44'/60'/0'/0",
        initialIndex,
      },
    },
    mainnet_eth_ledger: {
      type: "http",
      chainType: "l1",
      // Prefer MAINNET_RPC_URL (the same endpoint fork tests use, typically Alchemy);
      // fall back to Infura when only INFURA_API_KEY is set.
      url: process.env.MAINNET_RPC_URL || `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY ?? ""}`,
      ledgerAccounts: ["0xb741a35956AA2365c767734a5Ad6b8b60a41F8DD"],
      ledgerOptions: {
        derivationFunction: (index: number) => `m/44'/60'/0'/0/${index}`,
      },
    },
  },
};

export default config;
