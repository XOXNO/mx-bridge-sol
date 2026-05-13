import type { ContractTransactionResponse, TransactionReceipt } from "ethers";

import { readSetupConfig, type SetupConfig } from "./config.js";

const ETHEREUM_MAINNET_CHAIN_ID = 1n;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** Validate + normalize an address; require the chain to actually have code there. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function assertContract(connection: any, address: string, label: string): Promise<string> {
  const normalized = connection.ethers.getAddress(address);
  if (normalized === ZERO_ADDRESS) throw new Error(`${label} is the zero address`);
  // In Hardhat 3, `connection.provider` is the raw EIP-1193 provider (no ethers helpers).
  // The ethers-wrapped provider with `.getCode()` / `.getNetwork()` lives at
  // `connection.ethers.provider`.
  const code = (await connection.ethers.provider.getCode(normalized)) as string;
  if (!code || code === "0x") throw new Error(`${label} ${normalized} has no contract code`);
  return normalized;
}

/** Throws on non-mainnet unless the operator explicitly opted in. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function assertMainnet(connection: any, allowNonMainnet: string | undefined): Promise<void> {
  const network = await connection.ethers.provider.getNetwork();
  if (network.chainId === ETHEREUM_MAINNET_CHAIN_ID) return;
  if (allowNonMainnet === "true") {
    console.warn(`warning: chainId ${network.chainId} (--allow-non-mainnet enabled).`);
    return;
  }
  throw new Error(
    `chainId ${network.chainId} is not Ethereum mainnet (1). Re-run with --allow-non-mainnet true if intentional.`,
  );
}

/** Common bootstrap for every BridgeAdaptor task. */
export async function loadAdaptor(
  args: { configfile: string; allowNonMainnet?: string },
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  hre: any,
) {
  const connection = await hre.network.connect();
  const cfg: SetupConfig = readSetupConfig(args.configfile);

  const rawAddress = cfg.bridgeAdaptor;
  if (!rawAddress) {
    throw new Error(`bridgeAdaptor not set in ${args.configfile}. Run deploy-bridge-adaptor first.`);
  }

  await assertMainnet(connection, args.allowNonMainnet);
  const adaptorAddress = await assertContract(connection, rawAddress, "BridgeAdaptor");

  const [signer] = await connection.ethers.getSigners();
  const adaptor = await connection.ethers.getContractAt("BridgeAdaptor", adaptorAddress, signer);

  return { connection, cfg, adaptorAddress, signer, adaptor };
}

/** Await a tx and log result. Throws if status != 1. */
export async function confirmTx(
  tx: ContractTransactionResponse,
  label = "tx",
): Promise<TransactionReceipt> {
  console.log(`${label}: ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt) throw new Error(`${label}: receipt missing`);
  const ok = receipt.status === 1;
  console.log(
    `  block ${receipt.blockNumber}, gas ${receipt.gasUsed.toString()}, status: ${ok ? "OK" : "FAILED"}`,
  );
  if (!ok) throw new Error(`${label} reverted (${tx.hash})`);
  return receipt;
}
