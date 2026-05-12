import { task } from "hardhat/config";

import { CCTP_DOMAINS, fetchCctpMessage, resolveCctpDomain } from "../lib/circle.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  txhash: string;
  source: string;
}

export default withCommonAdaptorOptions(
  task("claim-cctp-v2-to-admin", "Settle out-of-limits CCTP V2 transfer to admin (calls settleOutOfLimitsCCTP)")
    .addOption({ name: "txhash", description: "Source chain transaction hash", defaultValue: "" })
    .addOption({
      name: "source",
      description: `Source chain (one of: ${Object.keys(CCTP_DOMAINS).join(", ")})`,
      defaultValue: "",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    if (!args.txhash || !args.source) throw new Error("--txhash and --source are required");

    const sourceDomain = resolveCctpDomain(args.source);
    console.log(`Source: ${args.source} (domain ${sourceDomain})`);
    console.log("Tx:", args.txhash);

    const msg = await fetchCctpMessage(sourceDomain, args.txhash);
    const cctpMessage = msg.message;
    const cctpAttestation = msg.attestation;

    const { adaptor, cfg, signer, connection } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    const adminAddress = (await adaptor.admin()) as string;
    console.log("Contract admin:", adminAddress);

    const usdcAddress = cfg.cctp?.usdc;
    if (!usdcAddress) throw new Error("cctp.usdc not set in config");
    const usdc = await connection.ethers.getContractAt("IERC20", usdcAddress);
    const adminBalanceBefore = (await usdc.balanceOf(adminAddress)) as bigint;

    const amountStr = msg.decodedMessage?.decodedMessageBody?.amount;
    if (amountStr) console.log("Amount:", connection.ethers.formatUnits(BigInt(amountStr), 6), "USDC");
    console.log("Admin USDC before:", connection.ethers.formatUnits(adminBalanceBefore, 6));

    console.log("Static-call simulating settleOutOfLimitsCCTP...");
    try {
      await adaptor.settleOutOfLimitsCCTP.staticCall(cctpMessage, cctpAttestation);
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      throw new Error(`Simulation failed: ${m}`);
    }
    console.log("Simulation OK.");

    const tx = await adaptor.settleOutOfLimitsCCTP(cctpMessage, cctpAttestation, getTxOverrides(args));
    await confirmTx(tx, "settleOutOfLimitsCCTP");

    const adminBalanceAfter = (await usdc.balanceOf(adminAddress)) as bigint;
    console.log("Admin USDC after:", connection.ethers.formatUnits(adminBalanceAfter, 6));
    console.log("Received:", connection.ethers.formatUnits(adminBalanceAfter - adminBalanceBefore, 6));
  })
  .build();
