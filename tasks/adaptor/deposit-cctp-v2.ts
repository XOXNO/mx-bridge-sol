import { task } from "hardhat/config";

import { CCTP_DOMAINS, fetchCctpMessage, resolveCctpDomain } from "../lib/circle.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  message: string;
  attestation: string;
  txhash: string;
  source: string;
}

export default withCommonAdaptorOptions(
  task("deposit-cctp-v2", "Call depositFromCCTPV2 on BridgeAdaptor (CCTP V2)")
    .addOption({ name: "message", description: "CCTP V2 message hex (0x...)", defaultValue: "" })
    .addOption({ name: "attestation", description: "CCTP attestation hex (0x...)", defaultValue: "" })
    .addOption({
      name: "txhash",
      description: "Source-chain tx hash (used with --source to fetch from Circle)",
      defaultValue: "",
    })
    .addOption({
      name: "source",
      description: `Source chain when using --txhash (one of: ${Object.keys(CCTP_DOMAINS).join(", ")})`,
      defaultValue: "",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    console.log("=== Deposit from CCTP V2 ===\n");

    let cctpMessage: string;
    let cctpAttestation: string;

    if (args.txhash) {
      if (!args.source) throw new Error("--source is required when using --txhash");
      const sourceDomain = resolveCctpDomain(args.source);
      console.log(`Source: ${args.source} (domain ${sourceDomain})`);
      console.log("Tx:", args.txhash);
      const msg = await fetchCctpMessage(sourceDomain, args.txhash);
      cctpMessage = msg.message;
      cctpAttestation = msg.attestation;
      console.log("Message status:", msg.status);
      console.log("Source domain:", msg.decodedMessage?.sourceDomain);
      console.log("Dest domain:", msg.decodedMessage?.destinationDomain);
      console.log("Nonce:", msg.decodedMessage?.nonce);
      console.log("Amount:", msg.decodedMessage?.decodedMessageBody?.amount);
      console.log("Mint recipient:", msg.decodedMessage?.decodedMessageBody?.mintRecipient);
    } else if (args.message && args.attestation) {
      cctpMessage = args.message;
      cctpAttestation = args.attestation;
    } else {
      throw new Error("Either --txhash + --source, or --message + --attestation, are required");
    }

    const { adaptor, adaptorAddress, signer } = await loadAdaptor(args, hre);
    console.log("BridgeAdaptor:", adaptorAddress);
    console.log("Signer:", await signer.getAddress());

    const circleTransmitter = (await adaptor.circleMessageTransmitter()) as string;
    console.log("Circle MessageTransmitter:", circleTransmitter);

    console.log("Static-call simulating depositFromCCTPV2...");
    try {
      await adaptor.depositFromCCTPV2.staticCall(cctpMessage, cctpAttestation);
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      throw new Error(`Simulation failed: ${m}`);
    }
    console.log("Simulation OK.");

    const tx = await adaptor.depositFromCCTPV2(cctpMessage, cctpAttestation, getTxOverrides(args));
    const receipt = await confirmTx(tx, "depositFromCCTPV2");

    for (const log of receipt.logs) {
      try {
        const parsed = adaptor.interface.parseLog({ topics: log.topics as string[], data: log.data });
        if (parsed) console.log(`event ${parsed.name}:`, parsed.args);
      } catch {
        // not from our contract
      }
    }
  })
  .build();
