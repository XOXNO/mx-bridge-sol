import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

import { getDeployOptions } from "../args/deployOptions.js";

export default task("adaptor-enable-wormhole", "Enable or disable Wormhole integration on BridgeAdaptor")
  .addOption({ name: "enabled", description: "true to enable, false to disable", defaultValue: "true" })
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    const enabled = args.enabled === "true";
    const connection = await hre.network.connect();

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as { bridgeAdaptor?: string };
    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) {
      throw new Error(`BridgeAdaptor address not found in ${args.configfile}`);
    }

    const [adminWallet] = await connection.ethers.getSigners();
    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, adminWallet);

    const tx = await adaptor.setWormholeEnabled(enabled, getDeployOptions(args));
    console.log("Transaction hash:", tx.hash);
    console.log("Wormhole integration", enabled ? "enabled" : "disabled");
  })
  .build();
