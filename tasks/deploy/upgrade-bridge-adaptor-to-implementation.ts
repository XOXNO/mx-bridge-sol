import { task } from "hardhat/config";

import { readSetupConfig } from "../lib/config.js";
import { assertContract, assertMainnet, confirmTx } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

const EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";
const EIP1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

interface Args extends CommonTaskArgs {
  implementation: string;
}

export default withCommonAdaptorOptions(
  task(
    "upgrade-bridge-adaptor-to-implementation",
    "Upgrade BridgeAdaptor proxy to an already deployed implementation",
  ).addOption({
    name: "implementation",
    description: "Already deployed BridgeAdaptor implementation address",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.implementation) throw new Error("--implementation is required");

    const connection = await hre.network.connect();
    await assertMainnet(connection, args.allowNonMainnet);

    const cfg = readSetupConfig(args.configfile);
    const rawAddress = cfg.bridgeAdaptor;
    if (!rawAddress) {
      throw new Error(`BridgeAdaptor address not set in ${args.configfile}. Run deploy-bridge-adaptor first.`);
    }

    const proxy = await assertContract(connection, rawAddress, "BridgeAdaptor proxy");
    const implementation = await assertContract(connection, args.implementation, "BridgeAdaptor implementation");
    const [signer] = await connection.ethers.getSigners();
    const signerAddress = await signer.getAddress();

    const readSlotAddress = async (slot: string) => {
      const raw = (await connection.ethers.provider.getStorage(proxy, slot)) as string;
      return connection.ethers.getAddress("0x" + raw.slice(-40));
    };

    const currentImplementation = await readSlotAddress(EIP1967_IMPLEMENTATION_SLOT);
    const proxyAdminAddress = await readSlotAddress(EIP1967_ADMIN_SLOT);
    const proxyAdmin = new connection.ethers.Contract(
      proxyAdminAddress,
      [
        "function owner() view returns (address)",
        "function upgradeAndCall(address proxy, address implementation, bytes data) payable",
      ],
      signer,
    );
    const owner = connection.ethers.getAddress((await proxyAdmin.owner()) as string);

    console.log("Signer:", signerAddress);
    console.log("Proxy:", proxy);
    console.log("ProxyAdmin:", proxyAdminAddress);
    console.log("ProxyAdmin owner:", owner);
    console.log("Current implementation:", currentImplementation);
    console.log("Target implementation:", implementation);

    if (connection.ethers.getAddress(signerAddress) !== owner) {
      throw new Error(`Signer ${signerAddress} is not ProxyAdmin owner ${owner}`);
    }
    if (currentImplementation === implementation) {
      console.log("Proxy already points to target implementation.");
      return;
    }

    await proxyAdmin.upgradeAndCall.staticCall(proxy, implementation, "0x");
    const tx = await proxyAdmin.upgradeAndCall(proxy, implementation, "0x", getTxOverrides(args));
    await confirmTx(tx, "upgradeAndCall");

    const upgradedImplementation = await readSlotAddress(EIP1967_IMPLEMENTATION_SLOT);
    console.log("Implementation after upgrade:", upgradedImplementation);
    if (upgradedImplementation !== implementation) {
      throw new Error(`Upgrade mismatch: expected ${implementation}, got ${upgradedImplementation}`);
    }
  })
  .build();
