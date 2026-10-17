# SwarmPeg (SWARMPEG)

A fixed-supply ERC-20 token built with the vendored OpenZeppelin Contracts v5.1.0
implementation. The only deployable application contract is
[`src/SwarmPeg.sol`](src/SwarmPeg.sol).

| Property | Value |
| --- | --- |
| Solidity contract | `SwarmPeg` |
| Token name | `SwarmPeg` |
| Symbol | `SWARMPEG` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Supply constant | `INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` |
| Initial recipient | Immediate constructor caller, `msg.sender` |
| Constructor arguments | None; ABI argument list `[]` |
| Constructor ETH value | `0` (nonpayable) |
| Intended launch chain | Ethereum, chain ID `1` |

## Behavior and assumptions

The entire supply is minted exactly once in the constructor, which emits
`Transfer(address(0), deployer, INITIAL_SUPPLY)`. During the IMD launch, the
deployer is the factory, so the factory receives every token. An ordinary direct
deployment instead credits the account or contract that creates the token.
`tx.origin` is never used. There are no external calls in the constructor.

Transfers deliver the exact amount requested. There are no token transfer fees,
rebases, burns, minting entry points, owner, pause, blacklist, seizure, upgrade,
or initialization functions. No price stabilization or asset backing is implied
by the name; the requested token is a standard fungible asset.

The ERC-20 interface exposes `name`, `symbol`, `decimals`, `totalSupply`,
`balanceOf`, `allowance`, `transfer`, `approve`, and `transferFrom`, plus the
read-only `INITIAL_SUPPLY` getter. Successful mutations return `true`; invalid
operations revert with OpenZeppelin's ERC-6093 custom errors. Zero-amount
transfers between nonzero addresses are valid and emit `Transfer`. Transfers
to the zero address and approvals for a zero spender revert. Self-transfers
preserve balances.

Approvals replace the existing allowance. Finite allowances decrease on
`transferFrom`; a maximum `uint256` allowance remains unchanged. Even a holder
calling `transferFrom` on their own balance needs an allowance; `transfer`
does not. `approve` emits `Approval`. As in OpenZeppelin v5, spending an
allowance does not emit another `Approval`; integrations should query the
current allowance. Reverted transfers leave balances and allowances unchanged.

## Build and test

The root Foundry project pins Solidity `0.8.26`, Cancun EVM output, optimization
at 200 runs, and `bytecode_hash = "none"`. It uses no FFI, filesystem cheatcodes,
RPC, fork, environment-dependent test setup, or external library linking.
All library sources and licences are included under `lib/`; see
[`DEPENDENCIES.md`](DEPENDENCIES.md) for versions and archive checksums.
With Foundry and the pinned compiler installed, the project builds offline.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x1605344090d614a49b3318101ccecfd551cda17d2a8b9649972c231568f55756 forge test
forge fmt --check
```

Validation completed with Foundry 1.8.3 and Solidity 0.8.26:

- `forge build` and a forced `forge build --offline --force` both passed.
- `forge test` passed with the seed above: 37 unit/fuzz tests and two stateful
  invariants, reported by Foundry as 38 passing tests (the invariant suite is
  grouped). There were 2,560 fuzz cases and 8,192 invariant actions, with no
  failures or skipped tests.
- `forge fmt --check` passed.
- The compiled runtime is 1,752 bytes and has no library link references.

Tests cover metadata and exact constructor allocation, a single mint event,
actual CREATE2 deployment through a test factory, exact launch transfer and
claim amounts, direct and delegated transfers, events, zero and maximum
values, self-transfers, approval replacement/revocation, finite and infinite
allowances, unauthorized spending, and atomic failure behavior. Tests also
probe absent mint/admin functions and forbidden runtime instructions.

Five fuzz properties run 512 cases each. Two stateful invariants run 128
sequences of 64 actions each, comparing balances and allowances against an
independent model after successful and rejected operations. Every test creates
its own contracts and uses local test actors; none requires live addresses or
keys. The factory helper under `test/` is test scaffolding, not a launch contract.

The launch-transfer test exercises token movements; it does not implement a
Uniswap pool or assert pricing. The supplied protected checks rely on a separate
launch harness, manifest, and pool implementation that are not part of this
project. Full factory/pool admission remains the launch verifier's responsibility.

## Deployment and operational responsibilities

Deploy the creation bytecode for `src/SwarmPeg.sol:SwarmPeg` without constructor
arguments or ETH. No initializer, owner address, linked library, or post-deploy
setting is needed. A factory must be able to forward its received tokens: this
contract does not distribute them automatically. The token's constructor does
not reserve or send tokens to any application contract.

The IMD launch process is responsible for the separate manifest, factory
deployment, the 10% swarm allocation, the 80% liquidity allocation, and the
remaining 10% allocation specified in the assignment. Pool creation, paired
currency, swap fees, opening price, and claim accounting belong to that launch
infrastructure. They are not token constructor parameters or token taxes.
This project supplies no `launch.json` and does not broadcast transactions.

Before release, the launch operator must confirm the built artifact and total
supply, complete independent review and the protected launch checks, then
verify the deployed source and constructor mint event. The build settings must
be kept consistent for bytecode verification.

### After launch

There are no setters, administrative keys, upgrades, or maintenance jobs.
The factory/distributor operators handle allocation and claims using ordinary
token transfers. Holders control their balances and approvals; the deployer
has no special authority over a holder's tokens.

Holders should approve only the amounts and spenders they intend to authorize.
To replace an existing nonzero allowance, revoke it and wait for confirmation
before setting another one, taking transaction ordering into account. Transfers
are irreversible, and tokens sent to an unusable address or to this token
contract cannot be recovered by an administrator. Direct ETH payments revert;
forcibly received ETH and other accidentally deposited assets have no recovery
function.

The delivered verification consists of Foundry build, unit/fuzz/invariant tests,
format checking, and source review against the supplied security reference.
Slither and Mythril were not run. These checks are not an independent security
audit.
