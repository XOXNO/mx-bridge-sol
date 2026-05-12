import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

export default withCommonAdaptorOptions(
  task("adaptor-cancel-admin-transfer", "Cancel a pending two-step admin transfer"),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: CommonTaskArgs, hre: any) => {
    const { adaptor, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const pending = (await adaptor.getPendingAdmin()) as string;
    console.log("Pending admin:", pending);
    if (pending === "0x0000000000000000000000000000000000000000") {
      throw new Error("No pending admin transfer to cancel");
    }

    const tx = await adaptor.cancelAdminTransfer(getTxOverrides(args));
    await confirmTx(tx, "cancelAdminTransfer");
  })
  .build();
