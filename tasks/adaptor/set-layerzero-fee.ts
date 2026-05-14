import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  feeBps: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-set-layerzero-fee", "Set LayerZero fee in basis points").addOption({
    name: "feeBps",
    description: "LayerZero fee basis points (5 = 0.05%; capped on-chain)",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.feeBps) throw new Error("--fee-bps is required");
    const feeBps = Number(args.feeBps);
    if (!Number.isInteger(feeBps) || feeBps < 0 || feeBps > 65_535) {
      throw new Error("--fee-bps must be an integer uint16");
    }

    const { adaptor, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const maxBps: bigint = await adaptor.MAX_LAYERZERO_FEE_BPS();
    if (BigInt(feeBps) > maxBps) {
      throw new Error(`LayerZero fee ${feeBps} bps exceeds on-chain cap of ${maxBps} bps`);
    }

    const tx = await adaptor.setLayerZeroFeeBps(feeBps, getTxOverrides(args));
    await confirmTx(tx, "setLayerZeroFeeBps");
    console.log("LayerZero fee set to:", feeBps, "bps");
  })
  .build();
