import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

import { getDeployOptions } from "../args/deployOptions.js";

const MAX_BPS = 10_000;

export default task("adaptor-set-fee-config", "Set fee configuration for BridgeAdaptor")
  .addOption({ name: "cctpFlatFee", description: "CCTP flat fee in token decimals (1e6 = 1 USDC)", defaultValue: "" })
  .addOption({ name: "wormholeFeeBps", description: "Wormhole fee basis points (5 = 0.05%)", defaultValue: "" })
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    if (!args.cctpFlatFee || !args.wormholeFeeBps) {
      throw new Error("--cctpFlatFee and --wormholeFeeBps are required");
    }
    const connection = await hre.network.connect();

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as { bridgeAdaptor?: string };
    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) {
      throw new Error(`BridgeAdaptor address not found in ${args.configfile}`);
    }

    const cctpFlatFee = BigInt(args.cctpFlatFee);
    const wormholeFeeBps = Number(args.wormholeFeeBps);
    if (wormholeFeeBps > MAX_BPS) {
      throw new Error(`Wormhole fee cannot exceed ${MAX_BPS} bps (100%)`);
    }

    const [adminWallet] = await connection.ethers.getSigners();
    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, adminWallet);

    console.log(`Setting fee config: CCTP flat fee = ${cctpFlatFee}, Wormhole fee = ${wormholeFeeBps} bps`);
    const tx = await adaptor.setFeeConfig(cctpFlatFee, wormholeFeeBps, getDeployOptions(args));
    console.log("Transaction hash:", tx.hash);
    console.log("Fee config updated");
  })
  .build();
