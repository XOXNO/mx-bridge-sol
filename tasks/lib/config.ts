import { readFileSync } from "node:fs";

/** Shape of `setup.config.json`. */
export interface SetupConfig {
  network?: string;
  erc20Safe?: string;
  bridgeAdaptor?: string;
  wormhole?: {
    chainId?: number;
    coreBridge?: string;
    tokenBridge?: string;
  };
  cctp?: {
    messageTransmitterV2?: string;
    usdc?: string;
  };
  layerZero?: {
    endpointV2?: string;
    usdt0OftAdapter?: string;
    usdt0LegacyMeshOft?: string;
    usdt?: string;
  };
}

export function readSetupConfig(path: string): SetupConfig {
  return JSON.parse(readFileSync(path, "utf8")) as SetupConfig;
}

/** Defaults the deploy task pulls from `setup.config.json` when CLI flags are omitted. */
export interface DeployDefaults {
  safe?: string;
  wormhole?: string;
  tokenBridge?: string;
  circleTransmitter?: string;
}

export function getDeployDefaults(cfg: SetupConfig): DeployDefaults {
  return {
    safe: cfg.erc20Safe,
    wormhole: cfg.wormhole?.coreBridge,
    tokenBridge: cfg.wormhole?.tokenBridge,
    circleTransmitter: cfg.cctp?.messageTransmitterV2,
  };
}

/** Pick the first non-empty string. Used to layer CLI override > config default. */
export function pick(...candidates: (string | undefined)[]): string | undefined {
  for (const c of candidates) {
    if (c && c.length > 0) return c;
  }
  return undefined;
}
