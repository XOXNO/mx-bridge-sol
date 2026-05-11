import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

import { getDeployOptions } from "../args/deployOptions.js";

// BridgeAdaptor uses a two-step admin transfer:
//   1. current admin calls transferAdmin(newAdmin)
//   2. newAdmin calls acceptAdmin()
// This task only initiates step 1.
export default task("adaptor-transfer-admin", "Start two-step admin transfer on BridgeAdaptor")
  .addOption({ name: "admin", description: "New admin address (must call acceptAdmin afterwards)", defaultValue: "" })
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    if (!args.admin) throw new Error("--admin is required");
    const connection = await hre.network.connect();

    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as { bridgeAdaptor?: string };
    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) {
      throw new Error(`BridgeAdaptor address not found in ${args.configfile}`);
    }

    const [adminWallet] = await connection.ethers.getSigners();
    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, adminWallet);
    const newAdmin = connection.ethers.getAddress(args.admin);

    const tx = await adaptor.transferAdmin(newAdmin, getDeployOptions(args));
    console.log("Transaction hash:", tx.hash);
    console.log(`Pending admin set to ${newAdmin} — call adaptor.acceptAdmin() from that wallet to finalize.`);
  })
  .build();
