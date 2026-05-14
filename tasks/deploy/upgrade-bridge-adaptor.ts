import { task } from "hardhat/config";
import { upgrades as upgradesFactory } from "@openzeppelin/hardhat-upgrades";

import { readSetupConfig } from "../lib/config.js";
import { assertContract, assertMainnet } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

export default withCommonAdaptorOptions(
  task("upgrade-bridge-adaptor", "Upgrades BridgeAdaptor implementation behind the proxy"),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: CommonTaskArgs, hre: any) => {
    const connection = await hre.network.connect();
    await assertMainnet(connection, args.allowNonMainnet);

    const cfg = readSetupConfig(args.configfile);
    const rawAddress = cfg.bridgeAdaptor;
    if (!rawAddress) {
      throw new Error(`BridgeAdaptor address not set in ${args.configfile}. Run deploy-bridge-adaptor first.`);
    }
    const adaptorAddress = await assertContract(connection, rawAddress, "BridgeAdaptor");

    const upgrades = await upgradesFactory(hre, connection);
    const [adminWallet] = await connection.ethers.getSigners();
    console.log("Admin Public Address:", adminWallet.address);
    console.log("Upgrading BridgeAdaptor at:", adaptorAddress);

    const BridgeAdaptor = await connection.ethers.getContractFactory("BridgeAdaptor", adminWallet);
    const upgraded = await upgrades.upgradeProxy(adaptorAddress, BridgeAdaptor, {
      txOverrides: getTxOverrides(args),
      unsafeAllow: ["constructor"],
      redeployImplementation: "always",
    });
    const newAddress = await upgraded.getAddress();
    console.log("BridgeAdaptor upgraded at:", newAddress);
  })
  .build();
