import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  enabled: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-enable-cctp", "Enable or disable CCTP integration on BridgeAdaptor").addOption({
    name: "enabled",
    description: "true to enable, false to disable",
    defaultValue: "true",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (args.enabled !== "true" && args.enabled !== "false") {
      throw new Error(`--enabled must be "true" or "false" (got "${args.enabled}")`);
    }
    const enabled = args.enabled === "true";
    const { adaptor, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const tx = await adaptor.setCCTPEnabled(enabled, getTxOverrides(args));
    await confirmTx(tx, "setCCTPEnabled");
    console.log("CCTP integration", enabled ? "enabled" : "disabled");
  })
  .build();
