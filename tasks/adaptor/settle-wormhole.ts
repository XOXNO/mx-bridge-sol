import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  vaa: string;
}

// Permissionless settlement of a Wormhole VAA whose amount falls outside Safe limits.
// Funds route to the current `admin()`; fee accrues to the contract.
export default withCommonAdaptorOptions(
  task("adaptor-settle-wormhole", "Settle out-of-limits Wormhole VAA to admin").addOption({
    name: "vaa",
    description: "Encoded VM (VAA) hex (0x...)",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.vaa) throw new Error("--vaa is required");
    if (!/^0x[0-9a-fA-F]+$/.test(args.vaa)) throw new Error("--vaa must be 0x-prefixed hex");

    const { adaptor, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    console.log("Static-call simulating settleOutOfLimitsWormhole...");
    try {
      await adaptor.settleOutOfLimitsWormhole.staticCall(args.vaa);
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      throw new Error(`Simulation failed: ${m}`);
    }
    console.log("Simulation OK.");

    const tx = await adaptor.settleOutOfLimitsWormhole(args.vaa, getTxOverrides(args));
    await confirmTx(tx, "settleOutOfLimitsWormhole");
  })
  .build();
