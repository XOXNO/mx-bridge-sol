/** Circle CCTP V2 source-domain registry (subset most relevant to xoxno). */
export const CCTP_DOMAINS: Record<string, number> = {
  ethereum: 0,
  avalanche: 1,
  optimism: 2,
  arbitrum: 3,
  noble: 4,
  solana: 5,
  base: 6,
  polygon: 7,
  sui: 8,
  aptos: 9,
  unichain: 10,
  linea: 11,
  codex: 12,
  sonic: 13,
  world: 14,
};

export interface CircleApiMessage {
  status: string;
  message: string;
  attestation: string;
  delayReason?: string;
  decodedMessage?: {
    sourceDomain?: number;
    destinationDomain?: number;
    nonce?: string;
    decodedMessageBody?: { amount?: string; mintRecipient?: string };
  };
}

interface CircleApiResponse {
  messages?: CircleApiMessage[];
}

export function resolveCctpDomain(source: string): number {
  const domain = CCTP_DOMAINS[source.toLowerCase()];
  if (domain === undefined) {
    throw new Error(
      `Unknown source chain "${source}". Valid: ${Object.keys(CCTP_DOMAINS).join(", ")}`,
    );
  }
  return domain;
}

/** Fetches a CCTP message from Circle's V2 Iris API.
 *  - Throws on missing message, pending attestation, or ambiguous result.
 *  - When `messageIndex` is undefined and the response contains multiple messages, the caller
 *    must disambiguate (this prevents accidentally settling the wrong burn).
 */
export async function fetchCctpMessage(
  sourceDomain: number,
  txHash: string,
  messageIndex?: number,
): Promise<CircleApiMessage> {
  const url = `https://iris-api.circle.com/v2/messages/${sourceDomain}?transactionHash=${txHash}`;
  const response = await fetch(url);
  const data = (await response.json()) as CircleApiResponse;
  const messages = data.messages ?? [];

  if (messages.length === 0) {
    throw new Error(`No CCTP message found for tx ${txHash} on domain ${sourceDomain}`);
  }
  if (messages.length > 1 && messageIndex === undefined) {
    throw new Error(
      `Tx ${txHash} produced ${messages.length} CCTP messages; pass --message-index 0..${messages.length - 1} to choose one.`,
    );
  }
  const idx = messageIndex ?? 0;
  if (idx < 0 || idx >= messages.length) {
    throw new Error(`--message-index ${idx} out of range (have ${messages.length} message(s))`);
  }
  const msg = messages[idx];
  if (msg.status !== "complete") {
    const tail = msg.delayReason ? ` (${msg.delayReason})` : "";
    throw new Error(`Attestation not ready. Status: ${msg.status}${tail}`);
  }
  return msg;
}
