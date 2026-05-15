import { task } from "hardhat/config";

import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  token: string;
  to: string;
  amount: string;
  all: string;
}

export default withCommonAdaptorOptions(
  task("adaptor-claim-fees", "Claim accrued BridgeAdaptor fees for a token")
    .addOption({ name: "token", description: "Token address to claim", defaultValue: "" })
    .addOption({ name: "to", description: "Recipient address (defaults to BridgeAdaptor admin)", defaultValue: "" })
    .addOption({
      name: "amount",
      description: "Amount in smallest units (mutually exclusive with --all)",
      defaultValue: "",
    })
    .addOption({
      name: "all",
      description: "Set 'true' to claim the full accrued fee balance",
      defaultValue: "false",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.token) throw new Error("--token is required");
    const claimAll = args.all === "true";
    if (!claimAll && !args.amount) throw new Error("Pass either --amount <units> or --all true");
    if (claimAll && args.amount) throw new Error("--amount and --all are mutually exclusive");

    const { adaptor, adaptorAddress, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const tokenAddress = connection.ethers.getAddress(args.token);
    const adminAddress = (await adaptor.admin()) as string;
    const recipient = connection.ethers.getAddress(args.to || adminAddress);
    console.log("Contract admin:", adminAddress);
    console.log("Recipient:", recipient);

    const erc20Abi = [
      "function balanceOf(address) view returns (uint256)",
      "function decimals() view returns (uint8)",
      "function symbol() view returns (string)",
    ];
    const token = new connection.ethers.Contract(tokenAddress, erc20Abi, signer);
    const [decimals, symbol, adaptorBalance, accrued, recipientBalanceBefore] = (await Promise.all([
      token.decimals(),
      token.symbol().catch(() => "?"),
      token.balanceOf(adaptorAddress),
      adaptor.accruedFees(tokenAddress),
      token.balanceOf(recipient),
    ])) as [bigint, string, bigint, bigint, bigint];
    const dec = Number(decimals);

    console.log(`Token: ${symbol} (${tokenAddress}, ${dec} dec)`);
    console.log("Adaptor balance:", connection.ethers.formatUnits(adaptorBalance, dec));
    console.log("Accrued fees:", connection.ethers.formatUnits(accrued, dec));
    console.log("Recipient balance before:", connection.ethers.formatUnits(recipientBalanceBefore, dec));

    const amountToClaim = claimAll ? accrued : BigInt(args.amount);
    if (amountToClaim === 0n) throw new Error("Nothing to claim (amount is 0)");
    if (amountToClaim > accrued) {
      throw new Error(`Requested ${amountToClaim} > accrued fees ${accrued}`);
    }
    if (amountToClaim > adaptorBalance) {
      throw new Error(`Requested ${amountToClaim} > adaptor token balance ${adaptorBalance}`);
    }
    console.log("Amount to claim:", connection.ethers.formatUnits(amountToClaim, dec));

    const tx = claimAll
      ? await adaptor.claimAllFees(tokenAddress, recipient, getTxOverrides(args))
      : await adaptor.claimFees(tokenAddress, recipient, amountToClaim, getTxOverrides(args));
    await confirmTx(tx, claimAll ? "claimAllFees" : "claimFees");

    const [accruedAfter, recipientBalanceAfter] = (await Promise.all([
      adaptor.accruedFees(tokenAddress),
      token.balanceOf(recipient),
    ])) as [bigint, bigint];
    console.log("Accrued fees after:", connection.ethers.formatUnits(accruedAfter, dec));
    console.log("Recipient balance after:", connection.ethers.formatUnits(recipientBalanceAfter, dec));
    console.log("Claimed:", connection.ethers.formatUnits(recipientBalanceAfter - recipientBalanceBefore, dec));
  })
  .build();
