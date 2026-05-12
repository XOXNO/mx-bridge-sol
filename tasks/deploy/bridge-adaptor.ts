import { writeFileSync } from "node:fs";

import { task } from "hardhat/config";
import { upgrades as upgradesFactory } from "@openzeppelin/hardhat-upgrades";

import { getDeployDefaults, pick, readSetupConfig } from "../lib/config.js";
import { assertContract, assertMainnet } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  safe: string;
  wormhole: string;
  tokenbridge: string;
  circletransmitter: string;
}

export default withCommonAdaptorOptions(
  task("deploy-bridge-adaptor", "Deploys BridgeAdaptor behind a transparent proxy")
    .addOption({
      name: "safe",
      description: "ERC20Safe address (defaults to setup.config.json#erc20Safe)",
      defaultValue: "",
    })
    .addOption({
      name: "wormhole",
      description: "Wormhole Core Bridge (defaults to setup.config.json#wormhole.coreBridge)",
      defaultValue: "",
    })
    .addOption({
      name: "tokenbridge",
      description: "Wormhole Token Bridge (defaults to setup.config.json#wormhole.tokenBridge)",
      defaultValue: "",
    })
    .addOption({
      name: "circletransmitter",
      description: "Circle MessageTransmitter V2 (defaults to setup.config.json#cctp.messageTransmitterV2)",
      defaultValue: "",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    const cfg = readSetupConfig(args.configfile);
    const defaults = getDeployDefaults(cfg);

    const safeAddr = pick(args.safe, defaults.safe);
    const wormholeAddr = pick(args.wormhole, defaults.wormhole);
    const tokenBridgeAddr = pick(args.tokenbridge, defaults.tokenBridge);
    const circleAddr = pick(args.circletransmitter, defaults.circleTransmitter);

    if (!safeAddr || !wormholeAddr || !tokenBridgeAddr || !circleAddr) {
      throw new Error(
        `Missing addresses. Provide via --safe / --wormhole / --tokenbridge / --circletransmitter ` +
          `or fill setup.config.json (erc20Safe, wormhole.coreBridge, wormhole.tokenBridge, cctp.messageTransmitterV2).`,
      );
    }

    const connection = await hre.network.connect();
    await assertMainnet(connection, args.allowNonMainnet);

    const [safe, wormhole, tokenBridge, circleTransmitter] = await Promise.all([
      assertContract(connection, safeAddr, "safe"),
      assertContract(connection, wormholeAddr, "wormhole"),
      assertContract(connection, tokenBridgeAddr, "tokenbridge"),
      assertContract(connection, circleAddr, "circletransmitter"),
    ]);

    const upgrades = await upgradesFactory(hre, connection);
    const [adminWallet] = await connection.ethers.getSigners();
    console.log("Admin Public Address:", adminWallet.address);
    console.log("Deploying BridgeAdaptor with:");
    console.log("  Safe:              ", safe);
    console.log("  Wormhole Core:     ", wormhole);
    console.log("  Token Bridge:      ", tokenBridge);
    console.log("  Circle Transmitter:", circleTransmitter);

    const BridgeAdaptor = await connection.ethers.getContractFactory("BridgeAdaptor", adminWallet);
    const adaptorContract = await upgrades.deployProxy(
      BridgeAdaptor,
      [safe, wormhole, tokenBridge, circleTransmitter],
      { kind: "transparent", txOverrides: getTxOverrides(args) },
    );

    await adaptorContract.waitForDeployment();
    const deployedAddress = await adaptorContract.getAddress();
    console.log("BridgeAdaptor deployed to:", deployedAddress);

    const cfgRaw = readSetupConfig(args.configfile) as Record<string, unknown>;
    cfgRaw.bridgeAdaptor = deployedAddress;
    writeFileSync(args.configfile, JSON.stringify(cfgRaw, null, 2) + "\n");
    console.log("Config saved to", args.configfile);
  })
  .build();
