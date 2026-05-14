import { task } from "hardhat/config";

import { pick } from "../lib/config.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

const ZERO = "0x0000000000000000000000000000000000000000";

interface Args extends CommonTaskArgs {
  oft: string;
  token: string;
  mesh: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-set-layerzero-oft-token", "Map a trusted LayerZero OFT/OFT Adapter to its local token")
    .addOption({
      name: "oft",
      description: "LayerZero OFT/OFT Adapter (defaults to setup.config.json#layerZero.usdt0OftAdapter)",
      defaultValue: "",
    })
    .addOption({
      name: "mesh",
      description: "USDT0 mesh default when --oft is omitted: native or legacy",
      defaultValue: "native",
    })
    .addOption({
      name: "token",
      description: "Credited ERC20 token (defaults to setup.config.json#layerZero.usdt; zero removes trust)",
      defaultValue: "",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    const { adaptor, cfg, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    if (args.mesh !== "native" && args.mesh !== "legacy") {
      throw new Error(`--mesh must be "native" or "legacy" (got "${args.mesh}")`);
    }
    const defaultOft = args.mesh === "legacy" ? cfg.layerZero?.usdt0LegacyMeshOft : cfg.layerZero?.usdt0OftAdapter;
    const oftRaw = pick(args.oft, defaultOft);
    const tokenRaw = pick(args.token, cfg.layerZero?.usdt);
    if (!oftRaw) {
      throw new Error(
        `--oft is required (or set ${args.mesh === "legacy" ? "layerZero.usdt0LegacyMeshOft" : "layerZero.usdt0OftAdapter"} in setup.config.json)`,
      );
    }
    if (!tokenRaw) throw new Error("--token is required (or set layerZero.usdt in setup.config.json)");

    const oft = connection.ethers.getAddress(oftRaw);
    const token = connection.ethers.getAddress(tokenRaw);
    if (oft === ZERO) throw new Error("--oft cannot be the zero address");

    const [oftCode, tokenCode] = await Promise.all([
      connection.ethers.provider.getCode(oft),
      token === ZERO ? "0x01" : connection.ethers.provider.getCode(token),
    ]);
    if (!oftCode || oftCode === "0x") throw new Error(`No contract code at OFT ${oft}`);
    if (!tokenCode || tokenCode === "0x") throw new Error(`No contract code at token ${token}`);

    const paused = (await adaptor.paused()) as boolean;
    if (!paused) {
      throw new Error("BridgeAdaptor must be paused before mapping a LayerZero OFT. Run adaptor-pause first.");
    }

    const tx = await adaptor.setLayerZeroOFTToken(oft, token, getTxOverrides(args));
    await confirmTx(tx, "setLayerZeroOFTToken");
    console.log("LayerZero OFT:", oft);
    console.log("Credited token:", token);
  })
  .build();
