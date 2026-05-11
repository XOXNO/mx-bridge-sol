import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

import { getDeployOptions } from "../args/deployOptions.js";

export default task("adaptor-set-circle-transmitter", "Set Circle MessageTransmitter on BridgeAdaptor")
  .addOption({ name: "transmitter", description: "Circle MessageTransmitter contract address", defaultValue: "" })
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    if (!args.transmitter) throw new Error("--transmitter is required");
    const connection = await hre.network.connect();

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as { bridgeAdaptor?: string };
    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) {
      throw new Error(`BridgeAdaptor address not found in ${args.configfile}`);
    }

    const [adminWallet] = await connection.ethers.getSigners();
    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, adminWallet);
    const transmitter = connection.ethers.getAddress(args.transmitter);

    const tx = await adaptor.setCircleTransmitter(transmitter, getDeployOptions(args));
    console.log("Transaction hash:", tx.hash);
    console.log(`Circle MessageTransmitter set to: ${transmitter}`);
  })
  .build();
