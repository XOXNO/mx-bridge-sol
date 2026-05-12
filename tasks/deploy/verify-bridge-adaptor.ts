import { task } from "hardhat/config";

import { readSetupConfig } from "../lib/config.js";
import { assertContract, assertMainnet } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, withCommonAdaptorOptions } from "../lib/options.js";

// Verifies the BridgeAdaptor proxy + implementation on Etherscan.
// Reads the proxy address from setup.config.json#bridgeAdaptor (override with --address).
// Requires ETHERSCAN_API_KEY in env (see .env.example).
export default withCommonAdaptorOptions(
  task("verify-bridge-adaptor", "Verify BridgeAdaptor proxy + implementation on Etherscan").addOption({
    name: "address",
    description: "Proxy address (defaults to setup.config.json#bridgeAdaptor)",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: CommonTaskArgs & { address: string }, hre: any) => {
    const cfg = readSetupConfig(args.configfile);
    const rawAddress = args.address || cfg.bridgeAdaptor;
    if (!rawAddress) {
      throw new Error(`BridgeAdaptor address not set. Pass --address <0x...> or fill setup.config.json#bridgeAdaptor.`);
    }

    const connection = await hre.network.connect();
    await assertMainnet(connection, args.allowNonMainnet);
    const proxy = await assertContract(connection, rawAddress, "BridgeAdaptor proxy");

    console.log("Verifying BridgeAdaptor at:", proxy);
    console.log("Etherscan submission may take ~30s...");

    // The standard `verify verify` subtask handles proxy + implementation verification
    // via the OZ-aware path. Equivalent to: `hardhat verify verify --network <net> <addr>`.
    await hre.tasks.getTask(["verify", "verify"]).run({
      address: proxy,
      // For TransparentUpgradeableProxy + Initializable, no constructor args are needed
      // for the proxy itself; the implementation has none either.
      constructorArgs: [],
    });

    console.log("Verification request submitted.");
    console.log("Check status at: https://etherscan.io/address/" + proxy + "#code");
  })
  .build();
