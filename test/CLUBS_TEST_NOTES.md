# Additional OGClubClubs tests

These additions use the delivered contracts and vendored Foundry dependencies.
They require no network, fork, environment mutation, or configuration changes.
The existing mint, levels, walls, layout, 285-piece capacity, constructor,
deployment, and custody tests remain in place.

| File | Added checks |
| --- | --- |
| `ClubsAtomicTransitions.t.sol` | Rejection after an ERC721 receiver has placed floor and wall furniture and transferred both NFTs rolls back payment, allowances, locks, custody, and mint rights; the identical mint can then succeed. A funded, authorized callback actor is blocked by the exact reentrancy error on both payment legs of mint and upgrade. Positive controls show that actor can mint and upgrade outside the callback. A token that changes balances before returning false fails atomically on either leg at every level, with successful retries. |
| `ClubsAtomicTransitions.t.sol` | Independently varied immutable prices conserve payments through all four levels (512 cases). Explicit boundaries cover total payments of `type(uint256).max`, an upgrade price of `type(uint256).max - 3`, and one-wei mint/upgrades using a token with no return data. Upgrade events and metadata updates are checked. |
| `ClubsDelegationInvariant.t.sol` | Four actors, six sparse Pepe IDs including zero and `uint256` maximum, nine randomly ordered actions, and an independent ownership, approval, delegation, and payment model. Includes revoked/wrong-scope delegations, transfers before/after minting, ERC721 approvals that cannot authorize minting, closed sales, missing Pepes/clubs, duplicate mints, operator upgrades, wallet depletion, short allowances, and level exhaustion. |
| `ClubsPlacementEncoding.t.sol` | Noncanonical uint8 words preserving otherwise valid low bytes, and short/long placement encodings with varied suffixes (512 cases each). Exact `BadPlacementData`, both complete occupancy maps, custody, designs, and footprint locks are checked before a valid retry. Zero and maximum furniture IDs stay distinct across floor and wall placements. |

The delegation invariant runs 256 sequences of 96 calls with unexpected handler
reverts treated as failures. Known successful delegated mints, operator upgrades,
authorization rejections, and second-leg allowance failures are seeded. Its
ghost accounting is updated from requested prices and intended transfers, not
observed burn/vault balance deltas. After every random call:

- Each club corresponds to a known Pepe minted exactly once; levels, current
  owners, approvals, ERC721 enumeration, and sale state agree with the model.
- Every actor's actual token balance equals its modeled balance.
- Burn and vault receipts equal all successful mint/upgrade payments; no payment
  remains in the club contract and the closed economy's supply is conserved.
- Rejected payments leave a snapshot of every tracked wallet and club unchanged.

After each sequence, ordinary token transfers redistribute the remaining budget
and every Pepe is minted and upgraded to level 4. This checks recovery from the
random history as well as safety during it. Existing layout invariant campaigns
continue to check geometry, permanent designs, and furniture custody.

The layout campaigns use `helpers/ClubsOccupancy.sol` to discover the floor and
wall storage slots through the public getters when each empty club is minted.
Discovery restores its temporary probes and does not hardcode mapping slots.
After every action, the complete storage words are compared with the independent
cell model, including unused wall bits and cells outside the current room.
Every public tile/wall getter is also checked against that model at the end of
each random sequence. The standalone layout fuzz test follows the same pattern.
This replaces hundreds of repeated external getter calls per club per action;
the existing run counts, sequence depths, geometry, custody, design, rejection,
and payment assertions are retained.

`ClubsOccupancy.t.sol` checks the reader against all public cells at random room
levels and arbitrary bitmap contents, exercises sparse IDs (zero and uint256
maximum), and confirms that hidden cells and unused wall bits are observable.
Only these reader tests inject storage; the behavior campaigns still use real
mint, upgrade, and ERC1155 placement calls.

The registry mock models exact ERC721 delegation keys, including holder,
collection, token ID, and rights. This is an integration test of the clubs' use
of that interface; it does not test live registry availability or the registry's
own wallet-wide/collection-wide delegation implementation. The zero club-token
balance property concerns protocol payments; the campaign does not send
unsolicited ERC20 donations. Test actors and mock tokens are local fixtures.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe91e85dcb3160b998a496c6801541e7340f6ef9be3d10de0d176fe7f8ec66c2d forge test
forge fmt --check
```
