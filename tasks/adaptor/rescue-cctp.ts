import { task } from "hardhat/config";

import { CCTP_DOMAINS, fetchCctpMessage, resolveCctpDomain } from "../lib/circle.js";
import { confirmTx, loadAdaptor } from "../lib/loadAdaptor.js";
import { type CommonTaskArgs, getTxOverrides, withCommonAdaptorOptions } from "../lib/options.js";

interface Args extends CommonTaskArgs {
  recipient: string;
  calldata: string;
  amount: string;
  txhash: string;
  source: string;
  messageIndex: string;
}

const HOOK_DATA_OFFSET_HEX = 376 * 2; // 376 bytes = 752 hex chars

// Used when USDC was minted directly to the adaptor by a `MessageTransmitter.receiveMessage`
// call that bypassed our adaptor (e.g. source-chain burn used destinationCaller=0).
//
// Two modes:
//   (a) --txhash + --source: fetch the CCTP message, decode hookData, derive recipient/calldata/amount.
//       Sanity-checks that mintRecipient == this adaptor.
//   (b) --recipient + --amount [+ --calldata]: pass values directly (raw override).
export default withCommonAdaptorOptions(
  task("adaptor-rescue-cctp", "Forward stranded USDC to a MultiversX recipient via the Safe")
    .addOption({
      name: "txhash",
      description: "Source-chain tx hash (auto-derives recipient/calldata/amount)",
      defaultValue: "",
    })
    .addOption({
      name: "source",
      description: `Source chain when using --txhash (one of: ${Object.keys(CCTP_DOMAINS).join(", ")})`,
      defaultValue: "",
    })
    .addOption({
      name: "messageIndex",
      description: "Index when the source tx produced multiple CCTP messages",
      defaultValue: "",
    })
    .addOption({
      name: "recipient",
      description: "Override: MultiversX recipient as 32-byte hex (0x-prefixed)",
      defaultValue: "",
    })
    .addOption({
      name: "calldata",
      description: "Override: SC execution calldata (0x for plain deposit)",
      defaultValue: "0x",
    })
    .addOption({
      name: "amount",
      description: "Override: USDC amount in 6-decimal units",
      defaultValue: "",
    }),
)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  .setInlineAction(async (args: Args, hre: any) => {
    const { adaptor, adaptorAddress, connection, signer } = await loadAdaptor(args, hre);
    console.log("Signer:", await signer.getAddress());

    let recipient: string;
    let calldataHex: string;
    let amount: bigint;

    if (args.txhash) {
      // Mode (a): derive from the on-the-wire Circle message.
      if (!args.source) throw new Error("--source is required when using --txhash");
      const sourceDomain = resolveCctpDomain(args.source);
      const messageIndex = args.messageIndex ? Number(args.messageIndex) : undefined;
      console.log(`Fetching CCTP message: tx ${args.txhash} on domain ${sourceDomain}`);
      const msg = await fetchCctpMessage(sourceDomain, args.txhash, messageIndex);

      // Sanity: mintRecipient must point at this adaptor.
      const mintRecipient = msg.decodedMessage?.decodedMessageBody?.mintRecipient;
      if (!mintRecipient) throw new Error("CCTP message has no decoded mintRecipient");
      const expected = "0x" + adaptorAddress.toLowerCase().replace(/^0x/, "").padStart(64, "0");
      if (mintRecipient.toLowerCase() !== expected) {
        throw new Error(
          `mintRecipient ${mintRecipient} does not target this adaptor ${adaptorAddress}; refusing to rescue.`,
        );
      }

      // Decode hookData = abi.encode(bytes32 mvxRecipient, bytes callData) at offset 376.
      const raw = msg.message.startsWith("0x") ? msg.message.slice(2) : msg.message;
      if (raw.length < HOOK_DATA_OFFSET_HEX + 96 * 2) {
        throw new Error("CCTP message too short to contain hookData");
      }
      const hookHex = "0x" + raw.slice(HOOK_DATA_OFFSET_HEX);
      const decoded = connection.ethers.AbiCoder.defaultAbiCoder().decode(["bytes32", "bytes"], hookHex);
      recipient = decoded[0] as string;
      calldataHex = decoded[1] as string;

      const amountStr = msg.decodedMessage?.decodedMessageBody?.amount;
      if (!amountStr) throw new Error("CCTP message has no decoded amount");
      amount = BigInt(amountStr);

      console.log("Derived from CCTP message:");
    } else {
      // Mode (b): explicit overrides.
      if (!args.recipient || !args.amount) {
        throw new Error("Either --txhash + --source, or --recipient + --amount, are required");
      }
      if (!/^0x[0-9a-fA-F]{64}$/.test(args.recipient)) {
        throw new Error("--recipient must be 0x + 64 hex chars (bytes32)");
      }
      if (!/^0x[0-9a-fA-F]*$/.test(args.calldata)) {
        throw new Error("--calldata must be 0x-prefixed hex");
      }
      recipient = args.recipient;
      calldataHex = args.calldata;
      amount = BigInt(args.amount);
      console.log("Using explicit override values:");
    }

    console.log("  Recipient:", recipient);
    console.log("  CallData length:", (calldataHex.length - 2) / 2, "bytes");
    console.log("  Amount:", connection.ethers.formatUnits(amount, 6), "USDC");

    console.log("Static-call simulating rescueAndForwardCCTP...");
    try {
      await adaptor.rescueAndForwardCCTP.staticCall(recipient, calldataHex, amount);
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      throw new Error(`Simulation failed: ${m}`);
    }

    const tx = await adaptor.rescueAndForwardCCTP(recipient, calldataHex, amount, getTxOverrides(args));
    await confirmTx(tx, "rescueAndForwardCCTP");
  })
  .build();
