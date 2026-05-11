import { readFileSync, writeFileSync } from "node:fs";

import { task } from "hardhat/config";
import { upgrades as upgradesFactory } from "@openzeppelin/hardhat-upgrades";

import { getDeployOptions } from "../args/deployOptions.js";

export default task("deploy-bridge-adaptor", "Deploys BridgeAdaptor behind a transparent proxy")
  .addOption({ name: "safe", description: "Address of the ERC20Safe contract", defaultValue: "" })
  .addOption({ name: "wormhole", description: "Address of the Wormhole Core Bridge", defaultValue: "" })
  .addOption({ name: "tokenbridge", description: "Address of the Wormhole Token Bridge", defaultValue: "" })
  .addOption({
    name: "circletransmitter",
    description: "Address of the Circle MessageTransmitter",
    defaultValue: "",
  })
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    if (!args.safe || !args.wormhole || !args.tokenbridge || !args.circletransmitter) {
      throw new Error("safe, wormhole, tokenbridge and circletransmitter are required");
    }

    const connection = await hre.network.connect();
    const upgrades = await upgradesFactory(hre, connection);

    const [adminWallet] = await connection.ethers.getSigners();
    console.log("Admin Public Address:", adminWallet.address);

    console.log("Deploying BridgeAdaptor with:");
    console.log("  Safe:", args.safe);
    console.log("  Wormhole Core:", args.wormhole);
    console.log("  Token Bridge:", args.tokenbridge);
    console.log("  Circle Transmitter:", args.circletransmitter);

    const BridgeAdaptor = await connection.ethers.getContractFactory("BridgeAdaptor", adminWallet);
    const adaptorContract = await upgrades.deployProxy(
      BridgeAdaptor,
      [args.safe, args.wormhole, args.tokenbridge, args.circletransmitter],
      { kind: "transparent", txOverrides: getDeployOptions(args) },
    );

    await adaptorContract.waitForDeployment();
    const deployedAddress = await adaptorContract.getAddress();
    console.log("BridgeAdaptor deployed to:", deployedAddress);

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as Record<string, unknown>;
    cfg.bridgeAdaptor = deployedAddress;
    writeFileSync(args.configfile, JSON.stringify(cfg, null, 2));
    console.log("Config saved to", args.configfile);
  })
  .build();
