import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

export default withCommonAdaptorOptions(task("adaptor-unpause", "Unpause BridgeAdaptor"))
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: CommonTaskArgs, hre: any) => {
    const { adaptor, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());
    const tx = await adaptor.unpause(getTxOverrides(args));
    await confirmTx(tx, "unpause");
  })
  .build();
