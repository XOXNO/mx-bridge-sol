import "dotenv/config";

import type { HardhatUserConfig } from "hardhat/config";
import { configVariable } from "hardhat/config";

import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";
import hardhatFoundry from "@nomicfoundation/hardhat-foundry";
import hardhatLedger from "@nomicfoundation/hardhat-ledger";
import hardhatUpgrades from "@openzeppelin/hardhat-upgrades";

import deployBridgeAdaptor from "./tasks/deploy/bridge-adaptor.js";
import upgradeBridgeAdaptor from "./tasks/deploy/upgrade-bridge-adaptor.js";
import enableWormhole from "./tasks/adaptor/enable-wormhole.js";
import unpauseAdaptor from "./tasks/adaptor/unpause-adaptor.js";
import pauseAdaptor from "./tasks/adaptor/pause-adaptor.js";
import setCustomAdmin from "./tasks/adaptor/set-custom-admin.js";
import setCircleTransmitter from "./tasks/adaptor/set-circle-transmitter.js";
import depositCctpV2 from "./tasks/adaptor/deposit-cctp-v2.js";
import claimCctpV2ToAdmin from "./tasks/adaptor/claim-cctp-v2-to-admin.js";
import recoverTokens from "./tasks/adaptor/recover-tokens.js";
import setFeeConfig from "./tasks/adaptor/set-fee-config.js";

const initialIndex = Number(process.env.INITIAL_INDEX ?? 0);

const solcSettings = {
  metadata: { bytecodeHash: "none" as const },
  optimizer: { enabled: true, runs: 1 },
  outputSelection: { "*": { "*": ["storageLayout"] } },
};

const config: HardhatUserConfig = {
  plugins: [hardhatToolboxMochaEthers, hardhatFoundry, hardhatLedger, hardhatUpgrades],
  tasks: [
    deployBridgeAdaptor,
    upgradeBridgeAdaptor,
    enableWormhole,
    pauseAdaptor,
    unpauseAdaptor,
    setCustomAdmin,
    setCircleTransmitter,
    depositCctpV2,
    claimCctpV2ToAdmin,
    recoverTokens,
    setFeeConfig,
  ],
  solidity: {
    profiles: {
      default: {
        compilers: [
          { version: "0.8.20", settings: solcSettings },
          { version: "0.8.22", settings: solcSettings },
        ],
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
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY ?? ""}`,
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
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY ?? ""}`,
      ledgerAccounts: ["0xb741a35956AA2365c767734a5Ad6b8b60a41F8DD"],
      ledgerOptions: {
        derivationFunction: (index: number) => `m/44'/60'/0'/0/${index}`,
      },
    },
  },
};

export default config;
