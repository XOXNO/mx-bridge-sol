import { upgrades as upgradesFactory } from "@openzeppelin/hardhat-upgrades";
import { task } from "hardhat/config";

import { readSetupConfig } from "../lib/config.js";
import { assertContract, assertMainnet } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, withCommonAdaptorOptions } from "../lib/options.js";

export default withCommonAdaptorOptions(
  task("validate-bridge-adaptor-upgrade", "Validate BridgeAdaptor upgrade safety without sending a transaction"),
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
    const BridgeAdaptor = await connection.ethers.getContractFactory("BridgeAdaptor");
    await upgrades.validateUpgrade(adaptorAddress, BridgeAdaptor, {
      unsafeAllow: ["constructor"],
    });

    console.log("BridgeAdaptor upgrade validation passed for proxy:", adaptorAddress);
  })
  .build();
