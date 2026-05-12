# Security

Trust model, threat model, and disclosure process for `BridgeAdaptor`. Read before integrating, auditing, or operating this contract.

## Scope

In-scope code:

- `contracts/BridgeAdaptor.sol`
- `contracts/interfaces/IERC20Safe.sol`
- The deployment + upgrade tasks under `tasks/deploy/`

Out of scope (depended on, not maintained here):

- The Wormhole Core Bridge + Token Bridge
- Circle's `MessageTransmitterV2`
- The MultiversX `ERC20Safe` and the off-chain MultiversX bridge validators
- OpenZeppelin upgradeable / SafeERC20 / ReentrancyGuard

## Trust model

The adaptor inherits trust from every party below.

| Actor                           | Authority over the adaptor                                                                                                                         | Worst-case failure                                                      | Mitigation in this code                                                                                                                                                                                                                 |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Wormhole guardian set**       | Signs VAAs that the adaptor accepts as proof of a remote transfer                                                                                  | Forged VAA mints non-existent funds and they end up on MultiversX       | None at this layer. We rely on Wormhole's 13/19 quorum. Per-protocol kill switch (`setWormholeEnabled(false)`) lets admin freeze the path within one tx                                                                                 |
| **Wormhole Token Bridge**       | Releases tokens to the adaptor on `completeTransferWithPayload`                                                                                    | Releases wrong amount or wrong token                                    | Post-call balance-delta check in `_receiveWormhole` (`amount = balanceAfter - balanceBefore`); whitelist + post-pull delta in `_depositToSafe`                                                                                          |
| **Circle attester**             | Signs CCTP V2 messages                                                                                                                             | Forged attestation mints USDC to the adaptor                            | None at this layer. Same kill-switch pattern via `setCCTPEnabled(false)`                                                                                                                                                                |
| **Circle MessageTransmitterV2** | Mints USDC to the adaptor on `receiveMessage`                                                                                                      | Mints wrong amount                                                      | Post-call balance-delta check in `_receiveCCTP`; CCTP V2 message version assertion (`messageVersion != 1` reverts)                                                                                                                      |
| **MultiversX ERC20Safe**        | Pulls tokens from the adaptor on `deposit()` / `depositWithSCExecution()`                                                                          | Pulls less than `netAmount` (silent fail / fee-on-transfer / blacklist) | Post-pull balance assertion in `_depositToSafe` reverts with `UnexpectedSafePullDelta` if delta ≠ `netAmount`                                                                                                                           |
| **BridgeAdaptor admin**         | Pause, set fees (capped), kill switches, rotate admin (2-step), update Wormhole/Circle refs (pause-gated), `rescueAndForwardCCTP`, `recoverTokens` | Drains stuck balances; routes settled out-of-limits funds to itself     | Two-step admin transfer (`transferAdmin` → `acceptAdmin`); fee caps (`MAX_WORMHOLE_FEE_BPS=1000`, `MAX_CCTP_FLAT_FEE=100e6`); `recoverTokens` is admin-only and emits `TokensRecovered`. **Recommended deployment: multisig as admin.** |
| **Permissionless callers**      | Call `depositFromWormhole`, `depositFromCCTPV2`, `settleOutOfLimitsWormhole`, `settleOutOfLimitsCCTP`                                              | None — they pay gas to forward already-attested transfers               | All entry points are `nonReentrant` and `whenNotPaused`; settlements route to `admin()`, not the caller                                                                                                                                 |

## Threat model

### What this code defends against

| Threat                                                        | Defense                                                                                                       |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Reentrancy from Safe or token callbacks                       | `nonReentrant` on every external entry point + post-call balance delta                                        |
| Misconfigured fees draining users                             | Hard caps enforced at write-time (`FeeExceedsMaxBps`, `FeeExceedsMaxFlat`)                                    |
| Hostile admin handover                                        | Two-step transfer with cancel; `_pendingAdmin` cleared on accept                                              |
| Replayed VAA / CCTP message                                   | Wormhole + Circle each ship their own replay protection; relying on it intentionally                          |
| Wrong-network deploy                                          | `initialize` requires `block.chainid == 1` (`WrongChain`)                                                     |
| CCTP V1 message smuggled into V2 path                         | `_extractAndDecodeHookData` asserts message version 1 (V2)                                                    |
| Direct `receiveMessage` strands USDC in the adaptor           | `rescueAndForwardCCTP` (admin-only); admin matches `(recipient, callData, amount)` to original burn off-chain |
| Out-of-limits VAA stuck forever                               | `settleOutOfLimitsWormhole` / `settleOutOfLimitsCCTP` route net-of-fee to admin                               |
| Fee-on-transfer / blacklist tokens silently breaking deposits | Whitelist check + post-pull balance delta in `_depositToSafe`                                                 |
| Silent storage drift on upgrade                               | Storage layout is pinned by Foundry tests via `vm.load` (`test/foundry/BridgeAdaptor.t.sol`)                  |
| Upgrade-time storage layout incompatibility                   | OZ upgrade-safety check in `tasks/deploy/upgrade-bridge-adaptor.ts`                                           |

### What this code does NOT defend against

| Threat                                                         | Why it's out of scope                                                                                              |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Compromised Wormhole guardian quorum                           | Out of our control; mitigated only by `setWormholeEnabled(false)` after detection                                  |
| Compromised Circle attester                                    | Same; mitigated only by `setCCTPEnabled(false)`                                                                    |
| Compromised admin private key                                  | Mitigated operationally — deploy admin as a multisig with a sane threshold                                         |
| Bugs inside the Safe, Wormhole, or Circle contracts            | These are independently audited dependencies                                                                       |
| Off-chain MultiversX validator failures (no mint, double mint) | Lives in the MultiversX bridge, not here                                                                           |
| MEV / front-running of `depositFromX`                          | Calls are idempotent (Wormhole/Circle replay protection prevents re-execution); no economic incentive to front-run |

## Known limitations

- **Single admin role.** No granular roles (e.g., separate "pauser" vs "fee setter"). Deliberate for v1 simplicity. If finer-grained control is needed, wrap with OZ `AccessControl` in a future major version.
- **No on-chain timelock.** `setFeeConfig` and `setWormholeEnabled` / `setCCTPEnabled` are immediate. Use a Timelock-controlled multisig as admin if delayed governance is required.
- **`recoverTokens` covers any ERC20.** Including wrapped versions of bridged tokens. Admin can sweep stuck balances; this is a feature for ops, not a back door — it cannot redirect in-flight transfers because every deposit forwards to the Safe atomically.
- **No formal verification.** Critical invariants (pulled-amount conservation, admin-only rescue) are covered by 93 unit tests + 5 mainnet-fork tests, not Halmos / Certora rules.
- **Static-analyzer suppressions.** Slither has 4 documented false-positive exclusions (see comments in `.github/workflows/ci.yml` slither step). Each is justified inline.

## Audit history

| Date      | Reviewer                                | Scope                       | Findings                  | Resolution                                        |
| --------- | --------------------------------------- | --------------------------- | ------------------------- | ------------------------------------------------- |
| 2026-05   | Internal AI-assisted multi-agent review | `BridgeAdaptor.sol` + tasks | 32 findings across passes | All addressed; commits in `git log --grep "fix:"` |
| _pending_ | External human firm                     | full scope                  | —                         | —                                                 |

Multiple agent passes covered known Solidity/DeFi vulnerability classes (entry-point analysis, insecure defaults, sharp edges, supply-chain risk, cross-protocol assumptions), followed by a second-opinion pass. Slither, Aderyn, and Semgrep (Trail of Bits ruleset) run on every CI build; Mythril runs weekly.

## Reporting a vulnerability

Email **security@xoxno.com** with:

1. A clear description of the issue and impact.
2. Steps to reproduce, ideally a Foundry test or PoC.
3. Suggested fix if you have one.

We will acknowledge within 72 hours. Please do not open public GitHub issues for security findings.

## Operational checklist for production

Before unpausing on mainnet:

- [ ] Admin is a multisig (not an EOA)
- [ ] `wormholeEnabled` and `cctpEnabled` start `true` only after both protocols are smoke-tested with small amounts on the deployed proxy
- [ ] `cctpFlatFee` and `wormholeFeeBps` are set to non-zero values that cover infrastructure costs without blocking small transfers
- [ ] Storage layout pin tests pass against the deployed implementation
- [ ] Etherscan verification has succeeded (`yarn bridge:verify`)
- [ ] Monitoring alerts on `Pause`, `AdminTransferred`, `FeeConfigUpdated`, `CCTPRescueForwarded`, `TokensRecovered`
