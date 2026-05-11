import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

interface SetupConfig {
  bridgeAdaptor?: string;
  cctp?: { usdc?: string };
}

interface CircleApiMessage {
  status: string;
  message: string;
  attestation: string;
  delayReason?: string;
  decodedMessage?: {
    sourceDomain?: number;
    destinationDomain?: number;
    nonce?: string;
    decodedMessageBody?: {
      amount?: string;
      mintRecipient?: string;
    };
  };
}

interface CircleApiResponse {
  messages?: CircleApiMessage[];
}

export default task("deposit-cctp-v2", "Call depositFromCCTPV2 on BridgeAdaptor (CCTP V2)")
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "message", description: "CCTP V2 message hex (0x...)", defaultValue: "" })
  .addOption({ name: "attestation", description: "CCTP attestation hex (0x...)", defaultValue: "" })
  .addOption({
    name: "txhash",
    description: "Solana transaction hash to fetch message/attestation from Circle API",
    defaultValue: "",
  })
  .setInlineAction(async (args, hre) => {
    const connection = await hre.network.connect();
    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as SetupConfig;

    console.log("=== Deposit from CCTP V2 ===\n");

    let cctpMessage: string;
    let cctpAttestation: string;

    if (args.txhash) {
      console.log("Fetching message and attestation from Circle V2 API for tx:", args.txhash);
      const response = await fetch(`https://iris-api.circle.com/v2/messages/5?transactionHash=${args.txhash}`);
      const data = (await response.json()) as CircleApiResponse;

      const msg = data.messages?.[0];
      if (!msg) {
        console.error("No messages found for this transaction");
        console.log("API Response:", JSON.stringify(data, null, 2));
        return;
      }

      console.log("Message status:", msg.status);
      if (msg.status !== "complete") {
        console.log("Attestation not ready yet. Delay reason:", msg.delayReason);
        return;
      }

      cctpMessage = msg.message;
      cctpAttestation = msg.attestation;

      console.log("Source Domain:", msg.decodedMessage?.sourceDomain);
      console.log("Dest Domain:", msg.decodedMessage?.destinationDomain);
      console.log("Nonce:", msg.decodedMessage?.nonce);
      console.log("Amount:", msg.decodedMessage?.decodedMessageBody?.amount);
      console.log("Mint Recipient:", msg.decodedMessage?.decodedMessageBody?.mintRecipient);
    } else if (args.message && args.attestation) {
      cctpMessage = args.message;
      cctpAttestation = args.attestation;
    } else {
      throw new Error("Either --txhash or both --message and --attestation are required");
    }

    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) throw new Error(`bridgeAdaptor not set in ${args.configfile}`);
    console.log("BridgeAdaptor:", adaptorAddress);

    const [signer] = await connection.ethers.getSigners();
    console.log("Signer:", await signer.getAddress());

    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, signer);

    const circleTransmitter = (await adaptor.circleMessageTransmitter()) as string;
    console.log("Circle MessageTransmitter:", circleTransmitter);

    console.log("Estimating gas for depositFromCCTPV2...");
    try {
      const gasEstimate = await adaptor.depositFromCCTPV2.estimateGas(cctpMessage, cctpAttestation);
      console.log("Gas estimate:", gasEstimate.toString());
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.log("Gas estimation failed:", msg);
      try {
        await adaptor.depositFromCCTPV2.staticCall(cctpMessage, cctpAttestation);
      } catch (staticError) {
        const sMsg = staticError instanceof Error ? staticError.message : String(staticError);
        console.log("Static call error:", sMsg);
      }
      return;
    }

    console.log("Sending depositFromCCTPV2 transaction...");
    const tx = await adaptor.depositFromCCTPV2(cctpMessage, cctpAttestation, { gasLimit: 500_000n });
    console.log("Transaction hash:", tx.hash);

    const receipt = await tx.wait();
    console.log("Confirmed in block:", receipt?.blockNumber);
    console.log("Gas used:", receipt?.gasUsed.toString());

    for (const log of receipt?.logs ?? []) {
      try {
        const parsed = adaptor.interface.parseLog({ topics: log.topics as string[], data: log.data });
        if (parsed) {
          console.log("Event:", parsed.name);
          console.log("  Args:", parsed.args);
        }
      } catch {
        // not an event from our contract
      }
    }
  })
  .build();
