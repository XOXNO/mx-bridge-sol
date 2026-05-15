import { task } from "hardhat/config";

import { loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  token: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-fees", "Read accrued BridgeAdaptor fees for a token").addOption({
    name: "token",
    description: "Token address to inspect",
    defaultValue: "",
  }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.token) throw new Error("--token is required");

    const { adaptor, adaptorAddress, connection } = await loadAdaptor(args, hre);
    const tokenAddress = connection.ethers.getAddress(args.token);
    const adminAddress = (await adaptor.admin()) as string;

    const erc20Abi = [
      "function balanceOf(address) view returns (uint256)",
      "function decimals() view returns (uint8)",
      "function symbol() view returns (string)",
    ];
    const token = new connection.ethers.Contract(tokenAddress, erc20Abi, connection.ethers.provider);
    const [decimals, symbol, adaptorBalance, adminBalance, accrued] = (await Promise.all([
      token.decimals(),
      token.symbol().catch(() => "?"),
      token.balanceOf(adaptorAddress),
      token.balanceOf(adminAddress),
      adaptor.accruedFees(tokenAddress),
    ])) as [bigint, string, bigint, bigint, bigint];
    const dec = Number(decimals);
    const unaccounted = adaptorBalance > accrued ? adaptorBalance - accrued : 0n;

    console.log(`Token: ${symbol} (${tokenAddress}, ${dec} dec)`);
    console.log("Adaptor balance:", connection.ethers.formatUnits(adaptorBalance, dec));
    console.log("Accrued fees:", connection.ethers.formatUnits(accrued, dec));
    console.log("Unaccounted balance:", connection.ethers.formatUnits(unaccounted, dec));
    console.log("Admin:", adminAddress);
    console.log("Admin balance:", connection.ethers.formatUnits(adminBalance, dec));
  })
  .build();
