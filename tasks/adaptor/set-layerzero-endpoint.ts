import { task } from "hardhat/config";

import { pick } from "../lib/config.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  endpoint: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-set-layerzero-endpoint", "Set LayerZero EndpointV2 on BridgeAdaptor (pause-gated)").addOption({
    name: "endpoint",
    description: "LayerZero EndpointV2 (defaults to setup.config.json#layerZero.endpointV2)",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    const { adaptor, cfg, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const endpointRaw = pick(args.endpoint, cfg.layerZero?.endpointV2);
    if (!endpointRaw) throw new Error("--endpoint is required (or set layerZero.endpointV2 in setup.config.json)");
    const endpoint = connection.ethers.getAddress(endpointRaw);
    if (endpoint === "0x0000000000000000000000000000000000000000") {
      throw new Error("--endpoint cannot be the zero address");
    }
    const code = (await connection.ethers.provider.getCode(endpoint)) as string;
    if (!code || code === "0x") throw new Error(`No contract code at ${endpoint}`);

    const paused = (await adaptor.paused()) as boolean;
    if (!paused) {
      throw new Error("BridgeAdaptor must be paused before setting LayerZero EndpointV2. Run adaptor-pause first.");
    }

    const tx = await adaptor.setLayerZeroEndpoint(endpoint, getTxOverrides(args));
    await confirmTx(tx, "setLayerZeroEndpoint");
    console.log("LayerZero EndpointV2 set to:", endpoint);
  })
  .build();
