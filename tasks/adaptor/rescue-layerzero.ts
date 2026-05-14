import { task } from "hardhat/config";

import { pick } from "../lib/config.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  token: string;
  recipient: string;
  calldata: string;
  amount: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-rescue-layerzero", "Forward stranded LayerZero-credited tokens to the MultiversX Safe")
    .addOption({
      name: "token",
      description: "Credited ERC20 token (defaults to setup.config.json#layerZero.usdt)",
      defaultValue: "",
    })
    .addOption({ name: "recipient", description: "MultiversX recipient bytes32 (0x...)", defaultValue: "" })
    .addOption({ name: "calldata", description: "Optional MvX SC execution calldata", defaultValue: "0x" })
    .addOption({ name: "amount", description: "Token amount in base units", defaultValue: "" }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.recipient) throw new Error("--recipient is required");
    if (!args.amount) throw new Error("--amount is required");
    if (!/^0x[0-9a-fA-F]{64}$/.test(args.recipient)) throw new Error("--recipient must be bytes32 hex");
    if (!/^0x([0-9a-fA-F]{2})*$/.test(args.calldata)) throw new Error("--calldata must be hex bytes");

    const { adaptor, cfg, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const tokenRaw = pick(args.token, cfg.layerZero?.usdt);
    if (!tokenRaw) throw new Error("--token is required (or set layerZero.usdt in setup.config.json)");
    const token = connection.ethers.getAddress(tokenRaw);
    if (token === "0x0000000000000000000000000000000000000000") throw new Error("--token cannot be the zero address");
    const amount = BigInt(args.amount);

    console.log("Static-call simulating rescueAndForwardLayerZero...");
    await adaptor.rescueAndForwardLayerZero.staticCall(token, args.recipient, args.calldata, amount);

    const tx = await adaptor.rescueAndForwardLayerZero(
      token,
      args.recipient,
      args.calldata,
      amount,
      getTxOverrides(args),
    );
    await confirmTx(tx, "rescueAndForwardLayerZero");
    console.log("Token:", token);
    console.log("Recipient:", args.recipient);
    console.log("Amount:", amount.toString());
  })
  .build();
