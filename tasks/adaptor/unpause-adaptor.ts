import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

import { getDeployOptions } from "../args/deployOptions.js";

export default task("adaptor-unpause", "Unpause BridgeAdaptor")
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    const connection = await hre.network.connect();

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as { bridgeAdaptor?: string };
    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) {
      throw new Error(`BridgeAdaptor address not found in ${args.configfile}`);
    }

    const [adminWallet] = await connection.ethers.getSigners();
    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, adminWallet);

    const tx = await adaptor.unpause(getDeployOptions(args));
    console.log("Transaction hash:", tx.hash);
    console.log("BridgeAdaptor unpaused");
  })
  .build();
