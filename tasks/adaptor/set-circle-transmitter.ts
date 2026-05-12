import { task } from "hardhat/config";

import { pick } from "../lib/config.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  transmitter: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-set-circle-transmitter", "Set Circle MessageTransmitter on BridgeAdaptor (pause-gated)").addOption({
    name: "transmitter",
    description: "Circle MessageTransmitter (defaults to setup.config.json#cctp.messageTransmitterV2)",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    const { adaptor, cfg, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const transmitterRaw = pick(args.transmitter, cfg.cctp?.messageTransmitterV2);
    if (!transmitterRaw) {
      throw new Error("--transmitter is required (or set cctp.messageTransmitterV2 in setup.config.json)");
    }
    const transmitter = connection.ethers.getAddress(transmitterRaw);
    if (transmitter === "0x0000000000000000000000000000000000000000") {
      throw new Error("--transmitter cannot be the zero address");
    }
    const code = (await connection.provider.getCode(transmitter)) as string;
    if (!code || code === "0x") throw new Error(`No contract code at ${transmitter}`);

    const paused = (await adaptor.paused()) as boolean;
    if (!paused) {
      throw new Error(
        "BridgeAdaptor must be paused before swapping the Circle MessageTransmitter. Run adaptor-pause first.",
      );
    }

    const tx = await adaptor.setCircleTransmitter(transmitter, getTxOverrides(args));
    await confirmTx(tx, "setCircleTransmitter");
    console.log("Circle MessageTransmitter set to:", transmitter);
  })
  .build();
