import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  admin: string;
}

// BridgeAdaptor uses a two-step admin transfer:
//   1. current admin calls transferAdmin(newAdmin)
//   2. newAdmin calls acceptAdmin()  (see adaptor-accept-admin)
// This task only initiates step 1.
export default withCommonAdaptorOptions(
  task("adaptor-transfer-admin", "Start two-step admin transfer on BridgeAdaptor").addOption({
    name: "admin",
    description: "New admin address (must call acceptAdmin afterwards)",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.admin) throw new Error("--admin is required");
    const { adaptor, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());
    const newAdmin = connection.ethers.getAddress(args.admin);

    const tx = await adaptor.transferAdmin(newAdmin, getTxOverrides(args));
    await confirmTx(tx, "transferAdmin");
    console.log(`Pending admin set to ${newAdmin} — call adaptor-accept-admin from that wallet to finalize.`);
  })
  .build();
