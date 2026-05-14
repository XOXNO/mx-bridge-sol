# mx-bridge-sol

Upgradeable Solidity adaptor that forwards Wormhole Token Bridge, Circle CCTP V2, and LayerZero OFT composed inbound transfers into the MultiversX `ERC20Safe`. **Ethereum mainnet only.**

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
yarn test         # forge test -vv (129 tests)
yarn coverage     # forge coverage summary
yarn lint         # solhint + eslint + prettier + forge fmt --check
```

## Deploy

```bash
yarn bridge:deploy
```

Constructor addresses come from `setup.config.json` (`erc20Safe`, `wormhole.coreBridge`, `wormhole.tokenBridge`, `cctp.messageTransmitterV2`); override any field via CLI flag (`--safe`, `--wormhole`, `--tokenbridge`, `--circletransmitter`). The proxy address writes back to `setup.config.json#bridgeAdaptor`.

Pre-flight checks: `chainId == 1` and every address has contract code. For forks, pass `--allow-non-mainnet true`.

## Upgrade

```bash
yarn bridge:upgrade
```

Uses the proxy from `setup.config.json`. OZ upgrade-safety check runs automatically.

## Verify on Etherscan

```bash
yarn bridge:verify          # uses setup.config.json#bridgeAdaptor
# or override:
yarn bridge:verify --address 0x<PROXY>
```

Requires `ETHERSCAN_API_KEY` in `.env` (free at <https://etherscan.io/myapikey>). Verifies proxy and implementation in a single submission. Targets the OZ TransparentUpgradeableProxy + Initializable layout this repo deploys.

## Fork integration tests

A separate suite under `test/foundry/BridgeAdaptorFork.t.sol` runs against a real Ethereum mainnet fork (real `ERC20Safe`, real `MessageTransmitterV2`, real USDC/USDT, real LayerZero EndpointV2 + USDT0 OFTs):

```bash
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/<KEY>"
forge test --match-path "test/foundry/BridgeAdaptorFork.t.sol" -vv
```

The suite skips cleanly when `MAINNET_RPC_URL` is unset. CI runs it as a separate job gated on the `MAINNET_RPC_URL` secret.

## Operations

All scripts default to `--network mainnet_eth`. Append `--price <gwei>` to set gas price; `--limit <units>` to override gas limit. Any other flag passes through to the underlying hardhat task.

| Script                                                           | Calls                       | Notes                                                                                                     |
| ---------------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------- |
| `yarn bridge:pause` / `yarn bridge:unpause`                      | `pause()` / `unpause()`     | Admin only                                                                                                |
| `yarn bridge:enable-wormhole --enabled true\|false`              | `setWormholeEnabled`        | Per-protocol kill-switch                                                                                  |
| `yarn bridge:enable-cctp --enabled true\|false`                  | `setCCTPEnabled`            | Per-protocol kill-switch                                                                                  |
| `yarn bridge:enable-layerzero --enabled true\|false`             | `setLayerZeroEnabled`       | Per-protocol kill-switch                                                                                  |
| `yarn bridge:set-fee --cctpFlatFee 1000000 --wormholeFeeBps 5`   | `setFeeConfig`              | Reads on-chain caps + validates                                                                           |
| `yarn bridge:set-layerzero-fee --fee-bps 5`                      | `setLayerZeroFeeBps`        | Reads on-chain cap + validates                                                                            |
| `yarn bridge:set-circle`                                         | `setCircleTransmitter`      | Defaults to `cctp.messageTransmitterV2` from config; pause-gated                                          |
| `yarn bridge:update-wormhole`                                    | `updateWormholeContracts`   | Defaults to `wormhole.coreBridge` + `wormhole.tokenBridge` from config; pause-gated                       |
| `yarn bridge:set-layerzero-endpoint`                             | `setLayerZeroEndpoint`      | Defaults to `layerZero.endpointV2` from config; pause-gated                                               |
| `yarn bridge:set-layerzero-oft-token --mesh native\|legacy`      | `setLayerZeroOFTToken`      | Defaults to USDT0 native/Legacy Mesh OFT → canonical USDT from config; pause-gated                        |
| `yarn bridge:set-layerzero-source --mesh native --src-eid 30110` | `setLayerZeroSource`        | Allows a source LayerZero EID for the configured OFT; pause-gated                                         |
| `yarn bridge:transfer-admin --admin 0x...`                       | `transferAdmin`             | Step 1 of two-step transfer                                                                               |
| `yarn bridge:accept-admin`                                       | `acceptAdmin`               | Step 2; signer must equal pending admin                                                                   |
| `yarn bridge:cancel-admin`                                       | `cancelAdminTransfer`       | Aborts a pending transfer                                                                                 |
| `yarn bridge:deposit-cctp --txhash <hash> --source <chain>`      | `depositFromCCTPV2`         | Fetches message + attestation from Circle Iris                                                            |
| `yarn bridge:settle-wormhole --vaa 0x...`                        | `settleOutOfLimitsWormhole` | Permissionless; routes funds to admin                                                                     |
| `yarn bridge:settle-cctp --txhash <hash> --source <chain>`       | `settleOutOfLimitsCCTP`     | Permissionless; routes funds to admin                                                                     |
| `yarn bridge:rescue-cctp --txhash <hash> --source <chain>`       | `rescueAndForwardCCTP`      | Admin rescue for direct-redeemed CCTP USDC; auto-decodes hookData and verifies `mintRecipient == adaptor` |
| `yarn bridge:rescue-layerzero --recipient 0x... --amount <n>`    | `rescueAndForwardLayerZero` | Admin rescue for LayerZero-credited tokens stranded before Safe deposit                                   |
| `yarn bridge:recover-tokens --token 0x... --all true`            | `recoverTokens`             | Sweep stuck balance; use `--amount` for partial                                                           |
| `yarn bridge:verify`                                             | Etherscan verify            | Reads proxy from `setup.config.json#bridgeAdaptor`; requires `ETHERSCAN_API_KEY` in `.env`                |

Hardware-wallet flow: re-target any task by calling `yarn hardhat <task> --network mainnet_eth_ledger ...` directly.

### LayerZero USDT0 setup

The LayerZero path is disabled by default. For USDT0 → Ethereum → MultiversX, pause the adaptor, set:

- `layerZero.endpointV2`: Ethereum EndpointV2, `0x1a44076050125825900e736c501f859c50fE728c`
- `layerZero.usdt0OftAdapter`: Ethereum native USDT0 OFT Adapter, `0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee`
- `layerZero.usdt0LegacyMeshOft`: Ethereum Legacy Mesh OFT, `0x1F748c76dE468e9D11bd340fA9D5CBADf315dFB0`
- `layerZero.usdt`: canonical Ethereum USDT, `0xdAC17F958D2ee523a2206206994597C13D831ec7`
- allowed source EIDs on the native OFT for website-supported USDT0 chains: `30110` Arbitrum, `30367` HyperEVM, `30339` Ink, `30111` Optimism, `30109` Polygon, `30390` Monad, `30280` Sei, `30320` Unichain
- allowed source EID on the Legacy Mesh OFT for Solana: `30168`

For the Solana USDT0 website path, configure both Ethereum OFTs: native for the EVM USDT0 mesh, and Legacy Mesh for Solana.

The source-chain `USDT0.send(...)` must target the BridgeAdaptor proxy as `to` and include `composeMsg = abi.encode(bytes32 mvxRecipient, bytes callData)`. LayerZero delivers the OFT credit first, then executes `lzCompose`; failed compose execution should be retried through LayerZero tooling before using `rescueAndForwardLayerZero`.

## Layout

```
contracts/BridgeAdaptor.sol                    production contract (Solidity 0.8.35)
contracts/interfaces/IERC20Safe.sol            Safe interface
contracts/interfaces/ILayerZeroComposer.sol    LayerZero composer interface
contracts/libraries/OFTComposeMsgCodec.sol     LayerZero OFT compose decoder
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

Every push and PR runs: `forge build`, `forge test`, `hardhat compile`, lint, Slither, Aderyn, Semgrep (Trail of Bits + smart-contracts rulesets), `forge coverage` → Codecov, and `forge fmt --check`. Mythril runs weekly via `.github/workflows/mythril.yml`.

Required GitHub Actions secrets:

| Secret              | Used by                                                               | Required?                                                 |
| ------------------- | --------------------------------------------------------------------- | --------------------------------------------------------- |
| `MAINNET_RPC_URL`   | `forge test` (fork suite) + `forge coverage`                          | required for fork tests; coverage falls back to unit-only |
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

Hardhat 3 + ESM. Depends on `@openzeppelin/hardhat-upgrades@^4.0.0-alpha.0` — the alpha line targeting Hardhat 3. Validate every upgrade on a fork before touching mainnet.

## Security

Trust model, threat model, known limitations, and disclosure process: [`SECURITY.md`](./SECURITY.md). Report vulnerabilities to **security@xoxno.com**.

## License

GPL-3.0
