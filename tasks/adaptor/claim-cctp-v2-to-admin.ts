import { readFileSync } from "node:fs";

import { task } from "hardhat/config";

import { getDeployOptions } from "../args/deployOptions.js";

const CCTP_DOMAINS: Record<string, number> = {
  ethereum: 0,
  avalanche: 1,
  optimism: 2,
  arbitrum: 3,
  base: 6,
  polygon: 7,
  solana: 5,
};

interface SetupConfig {
  bridgeAdaptor?: string;
  cctp?: { usdc?: string };
}

interface CircleApiMessage {
  status: string;
  message: string;
  attestation: string;
  decodedMessage?: {
    decodedMessageBody?: { amount?: string };
  };
}

interface CircleApiResponse {
  messages?: CircleApiMessage[];
}

export default task("claim-cctp-v2-to-admin", "Claim CCTP V2 transfer to admin by source tx hash")
  .addOption({ name: "txhash", description: "Source chain transaction hash", defaultValue: "" })
  .addOption({
    name: "source",
    description: `Source chain (one of: ${Object.keys(CCTP_DOMAINS).join(", ")})`,
    defaultValue: "",
  })
  .addOption({
    name: "configfile",
    description: "Config file path",
    defaultValue: "setup.config.json",
  })
  .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
  .setInlineAction(async (args, hre) => {
    if (!args.txhash || !args.source) throw new Error("--txhash and --source are required");
    const connection = await hre.network.connect();
    const cfg = JSON.parse(readFileSync(args.configfile, "utf8")) as SetupConfig;

    const sourceDomain = CCTP_DOMAINS[args.source.toLowerCase()];
    if (sourceDomain === undefined) {
      throw new Error(
        `Unknown source chain: ${args.source}. Valid: ${Object.keys(CCTP_DOMAINS).join(", ")}`,
      );
    }

    console.log("Source:", args.source, "(domain", sourceDomain + ")");
    console.log("Transaction hash:", args.txhash);

    const apiUrl = `https://iris-api.circle.com/v2/messages/${sourceDomain}?transactionHash=${args.txhash}`;
    const response = await fetch(apiUrl);
    const data = (await response.json()) as CircleApiResponse;

    const msg = data.messages?.[0];
    if (!msg) throw new Error("No CCTP message found for this transaction.");
    if (msg.status !== "complete") {
      throw new Error(`Attestation not ready. Status: ${msg.status}.`);
    }

    const cctpMessage = msg.message;
    const cctpAttestation = msg.attestation;
    const amount = msg.decodedMessage?.decodedMessageBody?.amount;
    if (amount) {
      console.log("Amount:", connection.ethers.formatUnits(BigInt(amount), 6), "USDC");
    }

    const [signer] = await connection.ethers.getSigners();
    console.log("Signer:", await signer.getAddress());

    const adaptorAddress = cfg.bridgeAdaptor;
    if (!adaptorAddress) throw new Error(`bridgeAdaptor not set in ${args.configfile}`);
    const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, signer);

    const adminAddress = (await adaptor.admin()) as string;
    console.log("Contract admin:", adminAddress);

    const usdcAddress = cfg.cctp?.usdc;
    if (!usdcAddress) throw new Error("cctp.usdc not set in config");
    const usdc = await connection.ethers.getContractAt("IERC20", usdcAddress);
    const adminBalanceBefore = (await usdc.balanceOf(adminAddress)) as bigint;
    console.log("Admin USDC balance before:", connection.ethers.formatUnits(adminBalanceBefore, 6));

    console.log("Simulating claimCCTPToAdmin...");
    try {
      await adaptor.claimCCTPToAdmin.staticCall(cctpMessage, cctpAttestation);
      console.log("Simulation successful.");
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      throw new Error(`Simulation failed: ${m}`);
    }

    const tx = await adaptor.claimCCTPToAdmin(cctpMessage, cctpAttestation, {
      gasLimit: 300_000n,
      ...getDeployOptions(args),
    });
    console.log("Transaction hash:", tx.hash);

    const receipt = await tx.wait();
    console.log("Confirmed in block:", receipt?.blockNumber);
    console.log("Gas used:", receipt?.gasUsed.toString());

    const adminBalanceAfter = (await usdc.balanceOf(adminAddress)) as bigint;
    console.log("Admin USDC balance after:", connection.ethers.formatUnits(adminBalanceAfter, 6));
    console.log("USDC received:", connection.ethers.formatUnits(adminBalanceAfter - adminBalanceBefore, 6));
  })
  .build();
