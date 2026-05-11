import { readFileSync } from "node:fs";

import { task } from "hardhat/config";
import { upgrades as upgradesFactory } from "@openzeppelin/hardhat-upgrades";

import { getDeployOptions } from "../args/deployOptions.js";

export default task("upgrade-bridge-adaptor", "Upgrades BridgeAdaptor implementation behind the proxy")
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    const connection = await hre.network.connect();
    const upgrades = await upgradesFactory(hre, connection);

    const [adminWallet] = await connection.ethers.getSigners();
    console.log("Admin Public Address:", adminWallet.address);

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as { bridgeAdaptor?: string };
    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) {
      throw new Error(`BridgeAdaptor address not found in ${args.configfile}`);
    }

    console.log("Upgrading BridgeAdaptor at:", adaptorAddress);

    const BridgeAdaptor = await connection.ethers.getContractFactory("BridgeAdaptor", adminWallet);
    const upgraded = await upgrades.upgradeProxy(adaptorAddress, BridgeAdaptor, {
      txOverrides: getDeployOptions(args),
    });
    const newAddress = await upgraded.getAddress();
    console.log("BridgeAdaptor upgraded at:", newAddress);
  })
  .build();
