import { task } from "hardhat/config";

import { readSetupConfig } from "../lib/config.js";
import { assertContract, assertMainnet } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, withCommonAdaptorOptions } from "../lib/options.js";

// Verifies the BridgeAdaptor proxy + implementation on Etherscan.
// Reads the proxy address from setup.config.json#bridgeAdaptor (override with --address).
// The implementation address is read from the EIP-1967 storage slot of the proxy.
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

    // EIP-1967 implementation slot.
    const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
    const implRaw = (await connection.ethers.provider.getStorage(proxy, IMPL_SLOT)) as string;
    const impl = connection.ethers.getAddress("0x" + implRaw.slice(-40));

    console.log("Proxy:", proxy);
    console.log("Impl: ", impl);
    console.log();

    // 1) Verify the implementation. No constructor args (impl uses an empty constructor
    //    that only calls _disableInitializers()).
    console.log("[1/2] Verifying implementation on Etherscan...");
    try {
      await hre.tasks.getTask(["verify", "etherscan"]).run({
        address: impl,
        constructorArgs: [],
      });
      console.log("  ✓ Implementation verification submitted.");
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes("Already Verified") || msg.includes("already verified")) {
        console.log("  ✓ Implementation already verified.");
      } else {
        throw err;
      }
    }

    // 2) Verify the proxy. Constructor args = (logic, initialOwner, data) where data is the
    //    abi-encoded `initialize(safe, wormhole, tokenBridge, circle)` call. Reconstruct from
    //    setup.config.json + the on-chain admin.
    console.log("\n[2/2] Verifying proxy on Etherscan...");
    const adaptorContract = await connection.ethers.getContractAt("BridgeAdaptor", proxy);
    const initialOwner = (await adaptorContract.admin()) as string;
    const safeAddr = cfg.erc20Safe;
    const wormholeAddr = cfg.wormhole.coreBridge;
    const tokenBridgeAddr = cfg.wormhole.tokenBridge;
    const circleAddr = cfg.cctp.messageTransmitterV2;
    if (!safeAddr || !wormholeAddr || !tokenBridgeAddr || !circleAddr) {
      throw new Error(
        `Missing config keys (erc20Safe, wormhole.coreBridge, wormhole.tokenBridge, cctp.messageTransmitterV2).`,
      );
    }
    const initData = adaptorContract.interface.encodeFunctionData("initialize", [
      safeAddr,
      wormholeAddr,
      tokenBridgeAddr,
      circleAddr,
    ]);
    try {
      await hre.tasks.getTask(["verify", "etherscan"]).run({
        address: proxy,
        contract:
          "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy",
        constructorArgs: [impl, initialOwner, initData],
      });
      console.log("  ✓ Proxy verification submitted.");
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (msg.includes("Already Verified") || msg.includes("already verified")) {
        console.log("  ✓ Proxy already verified.");
      } else {
        throw err;
      }
    }

    console.log("\nVerification complete.");
    console.log("Proxy:  https://etherscan.io/address/" + proxy + "#code");
    console.log("Impl:   https://etherscan.io/address/" + impl + "#code");
  })
  .build();
