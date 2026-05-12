import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

// Step 2 of the two-step admin transfer. Must be signed by the address that the current admin
// previously passed to `transferAdmin` (i.e. `getPendingAdmin()`).
export default withCommonAdaptorOptions(
  task("adaptor-accept-admin", "Pending admin accepts the two-step admin transfer"),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: CommonTaskArgs, hre: any) => {
    const { adaptor, signer } = await loadAdaptor(args, hre);
    const me = (await signer.getAddress()).toLowerCase();
    const pending = ((await adaptor.getPendingAdmin()) as string).toLowerCase();
    console.log("Signer:        ", me);
    console.log("Pending admin: ", pending);
    if (pending === "0x0000000000000000000000000000000000000000") {
      throw new Error("No pending admin transfer in progress");
    }
    if (pending !== me) {
      throw new Error(`Signer is not the pending admin (expected ${pending})`);
    }

    const tx = await adaptor.acceptAdmin(getTxOverrides(args));
    await confirmTx(tx, "acceptAdmin");
    console.log("Admin transfer complete. New admin:", await adaptor.admin());
  })
  .build();
