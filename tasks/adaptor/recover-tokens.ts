import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  token: string;
  amount: string;
  all: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-recover-tokens", "Recover stuck tokens from BridgeAdaptor to admin")
    .addOption({ name: "token", description: "Token address to recover", defaultValue: "" })
    .addOption({
      name: "amount",
      description: "Amount in smallest units (mutually exclusive with --all)",
      defaultValue: "",
    })
    .addOption({
      name: "all",
      description: "Set 'true' to sweep the full adaptor balance",
      defaultValue: "false",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.token) throw new Error("--token is required");
    const sweep = args.all === "true";
    if (!sweep && !args.amount) throw new Error("Pass either --amount <units> or --all true");
    if (sweep && args.amount) throw new Error("--amount and --all are mutually exclusive");

    const { adaptor, adaptorAddress, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());
    const tokenAddress = connection.ethers.getAddress(args.token);

    const adminAddress = (await adaptor.admin()) as string;
    console.log("Contract admin:", adminAddress);

    const erc20Abi = [
      "function balanceOf(address) view returns (uint256)",
      "function decimals() view returns (uint8)",
      "function symbol() view returns (string)",
    ];
    const token = new connection.ethers.Contract(tokenAddress, erc20Abi, signer);
    const [decimals, symbol, adaptorBalance, adminBalanceBefore] = (await Promise.all([
      token.decimals(),
      token.symbol().catch(() => "?"),
      token.balanceOf(adaptorAddress),
      token.balanceOf(adminAddress),
    ])) as [bigint, string, bigint, bigint];
    const dec = Number(decimals);

    console.log(`Token: ${symbol} (${tokenAddress}, ${dec} dec)`);
    console.log("Adaptor balance:", connection.ethers.formatUnits(adaptorBalance, dec));
    console.log("Admin balance before:", connection.ethers.formatUnits(adminBalanceBefore, dec));

    const amountToRecover = sweep ? adaptorBalance : BigInt(args.amount);
    if (amountToRecover === 0n) throw new Error("Nothing to recover (amount is 0)");
    if (amountToRecover > adaptorBalance) {
      throw new Error(`Requested ${amountToRecover} > adaptor balance ${adaptorBalance}`);
    }
    console.log("Amount to recover:", connection.ethers.formatUnits(amountToRecover, dec));

    // Pass 0 sentinel only when the contract should sweep; otherwise pass exact amount.
    const onChainArg = sweep ? 0n : amountToRecover;
    const tx = await adaptor.recoverTokens(tokenAddress, onChainArg, getTxOverrides(args));
    await confirmTx(tx, "recoverTokens");

    const adminBalanceAfter = (await token.balanceOf(adminAddress)) as bigint;
    console.log("Admin balance after:", connection.ethers.formatUnits(adminBalanceAfter, dec));
    console.log("Recovered:", connection.ethers.formatUnits(adminBalanceAfter - adminBalanceBefore, dec));
  })
  .build();
