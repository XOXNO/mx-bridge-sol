import type { Overrides } from "ethers";

/** Standard task args every adaptor task accepts. */
export interface CommonTaskArgs {
  configfile: string;
  price?: string;
  limit?: string;
  allowNonMainnet?: string;
}

/** Adds `--configfile`, `--price`, `--limit`, `--allow-non-mainnet` to a task builder.
 *  Hardhat 3's chainable builder type is internal; using `any` here keeps tasks decoupled.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function withCommonAdaptorOptions(builder: any): any {
  return builder
    .addOption({
      name: "configfile",
      description: "Path to setup.config.json",
      defaultValue: "setup.config.json",
    })
    .addOption({ name: "price", description: "Gas price in gwei", defaultValue: "" })
    .addOption({ name: "limit", description: "Gas limit override", defaultValue: "" })
    .addOption({
      name: "allowNonMainnet",
      description: "Set 'true' to bypass the mainnet chainId guard (use only on forks/devnets)",
      defaultValue: "false",
    });
}

/** Build ethers Overrides from the standard `--price` / `--limit` flags. */
export function getTxOverrides(args: CommonTaskArgs): Overrides {
  const overrides: Overrides = {};
  if (args.price) overrides.gasPrice = BigInt(args.price) * 1_000_000_000n;
  if (args.limit) overrides.gasLimit = BigInt(args.limit);
  return overrides;
}
