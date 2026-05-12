import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  cctpFlatFee: string;
  wormholeFeeBps: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-set-fee-config", "Set fee configuration for BridgeAdaptor")
    .addOption({
      name: "cctpFlatFee",
      description: "CCTP flat fee in token decimals (1e6 = 1 USDC; capped on-chain)",
      defaultValue: "",
    })
    .addOption({
      name: "wormholeFeeBps",
      description: "Wormhole fee basis points (5 = 0.05%; capped on-chain)",
      defaultValue: "",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.cctpFlatFee || !args.wormholeFeeBps) {
      throw new Error("--cctpFlatFee and --wormholeFeeBps are required");
    }
    const { adaptor, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    // Read on-chain caps so this task tracks contract changes automatically.
    const maxBps: bigint = await adaptor.MAX_WORMHOLE_FEE_BPS();
    const maxFlat: bigint = await adaptor.MAX_CCTP_FLAT_FEE();

    const cctpFlatFee = BigInt(args.cctpFlatFee);
    const wormholeFeeBps = BigInt(args.wormholeFeeBps);

    if (wormholeFeeBps > maxBps) {
      throw new Error(`Wormhole fee ${wormholeFeeBps} bps exceeds on-chain cap of ${maxBps} bps`);
    }
    if (cctpFlatFee > maxFlat) {
      throw new Error(`CCTP flat fee ${cctpFlatFee} exceeds on-chain cap of ${maxFlat}`);
    }

    console.log(
      `Setting fee config: CCTP flat = ${cctpFlatFee}, Wormhole = ${wormholeFeeBps} bps ` +
        `(caps: ${maxFlat}, ${maxBps})`,
    );
    const tx = await adaptor.setFeeConfig(cctpFlatFee, wormholeFeeBps, getTxOverrides(args));
    await confirmTx(tx, "setFeeConfig");
  })
  .build();
