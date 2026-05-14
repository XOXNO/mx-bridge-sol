import { task } from "hardhat/config";

import { pick } from "../lib/config.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  oft: string;
  srcEid: string;
  allowed: string;
  mesh: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-set-layerzero-source", "Allow or disallow a LayerZero source EID for a trusted OFT")
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
      name: "srcEid",
      description: "Source LayerZero endpoint ID, e.g. 30110 for Arbitrum",
      defaultValue: "",
    })
    .addOption({ name: "allowed", description: "true to allow, false to disallow", defaultValue: "true" }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.srcEid) throw new Error("--src-eid is required");
    if (args.allowed !== "true" && args.allowed !== "false") {
      throw new Error(`--allowed must be "true" or "false" (got "${args.allowed}")`);
    }
    const srcEid = Number(args.srcEid);
    if (!Number.isInteger(srcEid) || srcEid <= 0 || srcEid > 4_294_967_295) {
      throw new Error("--src-eid must be a uint32 greater than zero");
    }

    const { adaptor, cfg, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    if (args.mesh !== "native" && args.mesh !== "legacy") {
      throw new Error(`--mesh must be "native" or "legacy" (got "${args.mesh}")`);
    }
    const defaultOft = args.mesh === "legacy" ? cfg.layerZero?.usdt0LegacyMeshOft : cfg.layerZero?.usdt0OftAdapter;
    const oftRaw = pick(args.oft, defaultOft);
    if (!oftRaw) {
      throw new Error(
        `--oft is required (or set ${args.mesh === "legacy" ? "layerZero.usdt0LegacyMeshOft" : "layerZero.usdt0OftAdapter"} in setup.config.json)`,
      );
    }
    const oft = connection.ethers.getAddress(oftRaw);
    if (oft === "0x0000000000000000000000000000000000000000") throw new Error("--oft cannot be the zero address");

    const code = (await connection.ethers.provider.getCode(oft)) as string;
    if (!code || code === "0x") throw new Error(`No contract code at OFT ${oft}`);

    const paused = (await adaptor.paused()) as boolean;
    if (!paused) {
      throw new Error(
        "BridgeAdaptor must be paused before changing LayerZero source allowlist. Run adaptor-pause first.",
      );
    }

    const allowed = args.allowed === "true";
    const tx = await adaptor.setLayerZeroSource(oft, srcEid, allowed, getTxOverrides(args));
    await confirmTx(tx, "setLayerZeroSource");
    console.log("LayerZero OFT:", oft);
    console.log("Source EID:", srcEid);
    console.log("Allowed:", allowed);
  })
  .build();
