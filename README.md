# mx-bridge-sol

Upgradeable Solidity adaptor that forwards Wormhole Token Bridge and Circle CCTP V2 inbound transfers into the MultiversX `ERC20Safe`. **Ethereum mainnet only.**

| Address             |                                                       |
| ------------------- | ----------------------------------------------------- |
| ERC20Safe           | `0xC3c144d86c8840FD405acd637A548E850C636138`          |
| BridgeAdaptor proxy | recorded in `setup.config.json` after `bridge:deploy` |

## Requirements

- Node `>=22.22.1` (`nvm use`)
- Yarn 1.22
- Foundry (stable)
- `.env` with the keys in `.env.example`:
  - `MNEMONIC`, `INFURA_API_KEY`, `INITIAL_INDEX` — Hardhat signer + RPC
  - `ETHERSCAN_API_KEY` — only needed at deploy time for `yarn hardhat verify`
  - `MAINNET_RPC_URL` — Alchemy/Infura mainnet endpoint, required for `forge` fork tests

## Install + verify

```bash
nvm use
yarn install      # also activates the husky pre-commit hook
yarn build        # forge build && hardhat compile
yarn test         # forge test -vv (76 tests)
yarn coverage     # forge coverage summary
yarn lint         # solhint + eslint + prettier + forge fmt --check
```

## Deploy

```bash
yarn bridge:deploy
```

Reads every constructor address from `setup.config.json` (`erc20Safe`, `wormhole.coreBridge`, `wormhole.tokenBridge`, `cctp.messageTransmitterV2`). Override any field with the matching CLI flag (`--safe`, `--wormhole`, `--tokenbridge`, `--circletransmitter`). Writes the proxy address into `setup.config.json#bridgeAdaptor`. Validates `chainId == 1` and that every address has contract code. For forks: `--allow-non-mainnet true`.

## Upgrade

```bash
yarn bridge:upgrade
```

Uses the proxy from `setup.config.json`. OZ upgrade-safety check runs automatically.

## Operations

All scripts default to `--network mainnet_eth`. Pass extra flags with the standard yarn convention. Append `--price <gwei>` to set gas price; `--limit <units>` to override gas limit.

| Script                                                         | Calls                       | Notes                                                                                                     |
| -------------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------- |
| `yarn bridge:pause` / `yarn bridge:unpause`                    | `pause()` / `unpause()`     | Admin only                                                                                                |
| `yarn bridge:enable-wormhole --enabled true\|false`            | `setWormholeEnabled`        | Per-protocol kill-switch                                                                                  |
| `yarn bridge:enable-cctp --enabled true\|false`                | `setCCTPEnabled`            | Per-protocol kill-switch                                                                                  |
| `yarn bridge:set-fee --cctpFlatFee 1000000 --wormholeFeeBps 5` | `setFeeConfig`              | Reads on-chain caps + validates                                                                           |
| `yarn bridge:set-circle`                                       | `setCircleTransmitter`      | Defaults to `cctp.messageTransmitterV2` from config; pause-gated                                          |
| `yarn bridge:update-wormhole`                                  | `updateWormholeContracts`   | Defaults to `wormhole.coreBridge` + `wormhole.tokenBridge` from config; pause-gated                       |
| `yarn bridge:transfer-admin --admin 0x...`                     | `transferAdmin`             | Step 1 of two-step transfer                                                                               |
| `yarn bridge:accept-admin`                                     | `acceptAdmin`               | Step 2; signer must equal pending admin                                                                   |
| `yarn bridge:cancel-admin`                                     | `cancelAdminTransfer`       | Aborts a pending transfer                                                                                 |
| `yarn bridge:deposit-cctp --txhash <hash> --source <chain>`    | `depositFromCCTPV2`         | Fetches message + attestation from Circle Iris                                                            |
| `yarn bridge:settle-wormhole --vaa 0x...`                      | `settleOutOfLimitsWormhole` | Permissionless; routes funds to admin                                                                     |
| `yarn bridge:settle-cctp --txhash <hash> --source <chain>`     | `settleOutOfLimitsCCTP`     | Permissionless; routes funds to admin                                                                     |
| `yarn bridge:rescue-cctp --txhash <hash> --source <chain>`     | `rescueAndForwardCCTP`      | Admin rescue for direct-redeemed CCTP USDC; auto-decodes hookData and verifies `mintRecipient == adaptor` |
| `yarn bridge:recover-tokens --token 0x... --all true`          | `recoverTokens`             | Sweep stuck balance; use `--amount` for partial                                                           |

Hardware-wallet flow: re-target any task by calling `yarn hardhat <task> --network mainnet_eth_ledger ...` directly.

## Layout

```
contracts/BridgeAdaptor.sol         production contract (Solidity 0.8.35)
contracts/interfaces/IERC20Safe.sol Safe interface
contracts/test/                     Foundry mocks (not deployed)
test/foundry/BridgeAdaptor.t.sol    test suite (unit + 5000-run fuzz + storage-layout pins)
tasks/                              Hardhat 3 tasks
  lib/                              shared helpers (config, mainnet guard, address checks, Circle Iris)
  deploy/                           deploy + upgrade
  adaptor/                          ops (pause, fees, settle, rescue, recover, …)
hardhat.config.ts                   Hardhat 3 ESM, Ethereum mainnet only
foundry.toml                        Foundry config (solc 0.8.35, fuzz 5000, optimizer 200)
setup.config.json                   on-chain addresses (Safe, Wormhole, CCTP, USDC, deployed adaptor)
.openzeppelin/                      OZ upgrades manifest (created on first deploy)
.github/workflows/                  CI: build/test, slither, aderyn, coverage, semgrep, fmt; weekly mythril
```

## CI

Every push and PR runs: `forge build`, `forge test`, `hardhat compile`, lint, **Slither**, **Aderyn**, **Semgrep** (Trail of Bits + smart-contracts rulesets), **forge coverage** → Codecov, **forge fmt --check**. **Mythril** runs weekly via `.github/workflows/mythril.yml`.

Required GitHub Actions secrets:

| Secret              | Used by                                                               | Required?                                                 |
| ------------------- | --------------------------------------------------------------------- | --------------------------------------------------------- |
| `MAINNET_RPC_URL`   | `forge test` + `forge coverage` (pre-wired for fork tests)            | optional today; required when fork tests land             |
| `CODECOV_TOKEN`     | `coverage` job                                                        | required for private repos; optional for public           |
| `SEMGREP_APP_TOKEN` | `semgrep` job                                                         | optional (without it, Semgrep still gates the PR locally) |
| `ETHERSCAN_API_KEY` | not used in CI — operator-only at deploy time (`yarn hardhat verify`) | not needed in CI                                          |

Pre-commit hook (`.husky/pre-commit`) runs `forge fmt` on staged `.sol` files and `prettier --write` on staged `.ts/.json/.md/.yml` files.

## Editor / IDE

The repo ships with project configs for both VS Code and Zed:

- **VS Code** — `.vscode/settings.json` pins the JuanBlanco extension to solc 0.8.35 + `forge` formatter.
- **Zed** — `.zed/settings.json` wires Nomic Foundation's Solidity LSP (`@nomicfoundation/solidity-language-server`, installed via `yarn install`).

After cloning, `yarn install` is enough; both editors pick up the config on next reload.

## Toolchain notes

Hardhat 3 + ESM. Uses `@openzeppelin/hardhat-upgrades@^4.0.0-alpha.0` (the alpha HH3 line). Always validate upgrades on a fork before mainnet.

## License

GPL-3.0
