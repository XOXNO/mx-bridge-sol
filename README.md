# mx-bridge-sol — BridgeAdaptor

Upgradeable Solidity adaptor that bridges Wormhole Token Bridge and Circle CCTP V2 inbound transfers into the MultiversX `ERC20Safe`. Live deployment on Ethereum mainnet.

| Network | BridgeAdaptor proxy | ERC20Safe |
| --- | --- | --- |
| Ethereum mainnet | `0xF16a58D7876915c82E856f0f6F653e63280Be571` | `0xC3c144d86c8840FD405acd637A548E850C636138` |

## Layout

```
contracts/
  BridgeAdaptor.sol            production contract
  interfaces/IERC20Safe.sol    interface consumed from the bridge Safe
  test/                        Foundry mocks (Wormhole, TokenBridge, Circle, ERC20Safe, ERC20)
test/foundry/BridgeAdaptor.t.sol   primary test suite
tasks/                          Hardhat 3 tasks (deploy, upgrade, ops)
.openzeppelin/mainnet.json      OpenZeppelin upgrades manifest (preserves storage history)
foundry.toml / remappings.txt   Foundry config (forge-std + wormhole-solidity-sdk submodules)
hardhat.config.ts               Hardhat 3 ESM config, ETH mainnet only
setup.config.json               on-chain addresses (Safe, Wormhole, CCTP, USDC)
```

## Requirements

- Node `>=22.13.0` (see `.nvmrc`)
- Yarn 1.22 (Berry not required)
- Foundry stable
- `MNEMONIC` and `INFURA_API_KEY` in `.env` (see `.env.example`)

## Toolchain notes

This repo targets **Hardhat 3 + ESM**. The OpenZeppelin upgrades plugin used here is `@openzeppelin/hardhat-upgrades@^4.0.0-alpha.0`, the alpha HH3 line. Validate every upgrade locally and on a fork before submitting on-chain.

## Build & test

```bash
nvm use                # pick Node 22.13.1 from .nvmrc
yarn install           # install Hardhat + plugins
forge build            # compile + verify Foundry mocks
forge test -vv         # run the Foundry suite
yarn compile           # Hardhat compile (validates OZ upgrades against mainnet manifest)
yarn lint              # solhint + eslint + prettier
```

## Deploy a new BridgeAdaptor

```bash
yarn hardhat deploy-bridge-adaptor \
  --network mainnet_eth \
  --safe 0xC3c144d86c8840FD405acd637A548E850C636138 \
  --wormhole 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B \
  --tokenbridge 0x3ee18B2214AFF97000D974cf647E7C347E8fa585 \
  --circletransmitter 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64
```

Writes the proxy address back into `setup.config.json` under `bridgeAdaptor`.

## Upgrade the existing proxy

```bash
yarn hardhat upgrade-bridge-adaptor --network mainnet_eth
```

Uses the proxy address recorded in `setup.config.json` and the storage layout history in `.openzeppelin/mainnet.json`.

## Operations tasks

| Task | What it does |
| --- | --- |
| `adaptor-pause` / `adaptor-unpause` | Pause / unpause the adaptor |
| `adaptor-enable-wormhole --enabled true\|false` | Toggle Wormhole integration |
| `adaptor-set-circle-transmitter --transmitter 0x...` | Update Circle MessageTransmitter |
| `adaptor-set-fee-config --cctp-flat-fee 1000000 --wormhole-fee-bps 5` | Set fees (CCTP flat, Wormhole bps) |
| `adaptor-transfer-admin --admin 0x...` | Start two-step admin transfer (new admin must call `acceptAdmin()`) |
| `adaptor-recover-tokens --token 0x... [--amount 0]` | Recover stuck tokens to current admin |
| `deposit-cctp-v2 --txhash <solana-tx>` | Pull message+attestation from Circle and deposit via the adaptor |
| `claim-cctp-v2-to-admin --txhash <tx> --source solana\|ethereum\|...` | Claim out-of-limit CCTP transfer directly to admin |

All admin tasks read the proxy address from `setup.config.json` (override with `--configfile <path>`) and the gas price (gwei) with `--price`.

## License

GPL-3.0
