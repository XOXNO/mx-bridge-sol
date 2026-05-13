import { task } from "hardhat/config";

import { pick } from "../lib/config.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  wormhole: string;
  tokenbridge: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-update-wormhole", "Swap Wormhole core+token-bridge addresses (pause-gated)")
    .addOption({
      name: "wormhole",
      description: "Wormhole Core Bridge (defaults to setup.config.json#wormhole.coreBridge)",
      defaultValue: "",
    })
    .addOption({
      name: "tokenbridge",
      description: "Wormhole Token Bridge (defaults to setup.config.json#wormhole.tokenBridge)",
      defaultValue: "",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    const { adaptor, cfg, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const wormholeRaw = pick(args.wormhole, cfg.wormhole?.coreBridge);
    const tokenBridgeRaw = pick(args.tokenbridge, cfg.wormhole?.tokenBridge);
    if (!wormholeRaw || !tokenBridgeRaw) {
      throw new Error(
        "--wormhole and --tokenbridge are required (or set wormhole.coreBridge / wormhole.tokenBridge in setup.config.json)",
      );
    }

    const wormhole = connection.ethers.getAddress(wormholeRaw);
    const tokenBridge = connection.ethers.getAddress(tokenBridgeRaw);
    const ZERO = "0x0000000000000000000000000000000000000000";
    if (wormhole === ZERO || tokenBridge === ZERO) throw new Error("addresses must be non-zero");

    const [wCode, tbCode] = await Promise.all([
      connection.ethers.provider.getCode(wormhole),
      connection.ethers.provider.getCode(tokenBridge),
    ]);
    if (wCode === "0x") throw new Error(`No contract code at wormhole ${wormhole}`);
    if (tbCode === "0x") throw new Error(`No contract code at tokenbridge ${tokenBridge}`);

    const paused = (await adaptor.paused()) as boolean;
    if (!paused) {
      throw new Error("BridgeAdaptor must be paused before swapping Wormhole contracts. Run adaptor-pause first.");
    }

    await adaptor.updateWormholeContracts.staticCall(wormhole, tokenBridge);

    const tx = await adaptor.updateWormholeContracts(wormhole, tokenBridge, getTxOverrides(args));
    await confirmTx(tx, "updateWormholeContracts");
    console.log("Wormhole core:        ", wormhole);
    console.log("Wormhole token bridge:", tokenBridge);
  })
  .build();
