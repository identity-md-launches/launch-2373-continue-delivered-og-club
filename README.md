# OG Club clubs, staking, furniture and raffles

OG Club awards ERC-1155 furniture through raffles paid with nontransferable points
accrued by staking OG. There are no lootboxes or token-paid furniture purchases.
`OGClubClubs` adds transferable ERC-721 rooms bought with OG. Furniture can be
placed in a room permanently; the on-chain layout and its contents follow the
club when it is sold. This revision adapts only OGClubClubs from the delivered clubs repository at
`292e20dec8afa05dc98367c8a9f47bd39a4b66a5`; the existing furniture, staking,
farm vault, raffle, MockOG and libraries are unchanged.
This Foundry project uses the existing Solidity 0.8.26/Cancun configuration and
vendored OpenZeppelin 5.0.2 / forge-std 1.9.7 dependencies ([VENDOR.md](VENDOR.md)).
Builds and tests require no RPC, secrets, FFI, or downloaded dependencies.

## Contracts and configuration

All constructors are nonpayable, use explicit owners, and make no dependency
calls. They can run on an empty chain through the launch factory. Contracts are
immutable implementations, without proxies, code upgrades, transfer pauses or owner sweeps.
Ownership uses OpenZeppelin's two-step transfer. Libraries are internal/inlined.

| Contract | Constructor arguments, in order |
| --- | --- |
| `MockOG` | initial recipient (Sepolia/local only) |
| `OGClubFurniture` | owner, initial royalty receiver |
| `OGClubFarmVault` | token, owner |
| `OGClubStaking` | token, immutable vault, owner, pointsPerTokenDay |
| `OGClubRaffle` | staking, furniture, owner, immutable raffleNotice |
| `MockSwarmPepe` | none (Sepolia-only public mint) |
| `OGClubClubs` | token, vault, price, furniture, owner, royaltyReceiver, pepes, delegates, UpgradePrices |

The supplied `launch.json` is for **Sepolia, chain ID 11155111**, and deploys these
seven contracts in that order. `$owner` is the launch's configured owner
(`0x5b95a971b4583a5f011e9da082acdd679b870d06`); contract
references resolve to the preceding deployments. MockOG deliberately has
unrestricted minting, so anyone can acquire arbitrary stake and raffle points on
this test network. **MockOG is Sepolia-only** (also used in local tests). Its initial trillion-token
supply is not a cap. Do not reuse
this manifest for mainnet.

The selected testnet accrual rate is **1e18 point units per whole token per day**
(one point); `Deploy.DEFAULT_POINTS_PER_TOKEN_DAY` names this default. Ticket
prices are owner-announced point amounts in each pool, not an ERC-20 payment.
Other fixed limits are three blocks for `TARGET_DELAY`, 32 pools and 128 total
prize lines per raffle, and 30 days for the maximum raffle notice.

## Owner setup and mainnet handoff

The factory performs constructor deployments only. **It cannot grant the two
raffle roles.** After deployment, the configured owner must execute these calls,
using the confirmed deployed raffle address, before creating the first raffle:

1. `furniture.grantMinter(raffle)` as the furniture's **first successful grant**.
2. `staking.grantSpender(raffle)` as staking's **first successful grant**.
3. Verify `minters(raffle)` and `spenders(raffle)` are true, set the furniture
   base URI, then create the announced raffles.

The first grant in each contract is immediate and permanently spends that
contract's bootstrap. Granting another address first makes the raffle wait. All
later grants, including re-grants of revoked roles, are seven-day proposals.
Anyone can activate in `[activatesAt, activatesAt + 7 days]`, inclusive. At the
next second the proposal is absent for activation/cancellation; its raw mapping
value may remain until a new proposal or revocation. Re-proposing restarts the
full delay. Cancel only removes a live proposal; revoke immediately clears both
permission and any proposal. Neither supply nor ownership handover resets this.

For a separate **mainnet** launch:

- Use the **existing OG token**, never deploy MockOG. The actual token address
  is an operator input, not a guessed address in this repository.
- Use a **fresh deployer** and set **OWNER to a Safe**. The deployer/factory gains
  no ownership and cannot perform the Safe's role grants.
- Set **RAFFLE_NOTICE=604800** (seven days). Sepolia uses zero.
- `script/Deploy.s.sol` takes `TOKEN`, `OWNER`, `RAFFLE_NOTICE`, and optionally
  `POINTS_PER_TOKEN_DAY` (default 1e18). Its `deploy` helper builds the four
  production applications; `deploySepolia` additionally creates MockOG and is
  restricted to Sepolia/local chain IDs. Both leave role grants to the owner.
  This existing script remains the raffle-stack helper; the separate club
  scripts described below add the new application.

No contract has been deployed or broadcast as part of this work.

## Clubs: Pepe minting, levels and permanent layouts

Clubs are **OG Club Clubs**, symbol **OGCLUBS**. Call `mintClub(pepeId)` after
approving exactly `price` OG. The caller must own that Swarm Pepe or have a
valid delegate.xyz v2 delegation from its current holder. The registry query is
`checkDelegateForERC721(caller, holder, pepes, pepeId, bytes32(0))`.
Ordinary ERC-721 transfer approvals do not authorize club minting. Passing zero
for `delegates` disables delegation; `pepes` must be nonzero.

The caller pays and receives club **#pepeId**, with safe ERC-721 delivery.
`clubsMinted(pepeId)` records the lifetime mint right: neither selling the Pepe
nor selling its club resets it. Zero, sparse and large Pepe IDs are preserved.
There is no sequential allocation, gifting mint entry point, free owner mint or
club burn. A nonexistent Pepe reverts through its ERC-721 `ownerOf` call.
`ClubMinted(id, to, payer, pepeId, burned, toVault)` records the purchase.

Every club starts empty at level 1. `upgradeClub(clubId)` lets its holder,
token-approved account or operator pay the next level's immutable price.
The caller pays, even when it is an approved operator. Minting and upgrading are
nonReentrant. Sale control gates minting only; transfers, furnishing and upgrades
remain available when the sale is closed. A level-4 upgrade reverts `MaxLevel`.

| Level | Room size | Price to reach this level (18-decimal OG) |
| --- | --- | --- |
| 1 | 10x10 | Mint: 100_000e18 on Sepolia |
| 2 | 12x12 | 200_000e18 |
| 3 | 14x14 | 400_000e18 |
| 4 | 16x16 | 800_000e18 |

The constructor fixes the three upgrade prices, each greater than zero, using
`UpgradePrices { uint256 level2; uint256 level3; uint256 level4; }`.
This static struct is the factory-compatible representation of the requested
three-price array. The manifest flattens its fields into three words, in that
order. A `uint256[3]` ABI argument must not be paired with three separate
manifest entries: that caused the previous launch rejection. The three values
are stored in immutable fields and have no setters.

Room size is `8 + 2*level`. Growth adds rows and columns at the front; `(0,0)`
stays the back corner and no existing piece moves. `ClubUpgraded(clubId,
newLevel, payer, burned, toVault)` and `MetadataUpdate(clubId)` announce upgrades.

Each mint or upgrade transfers `floor(amount/2)` directly from the payer to
`0x000000000000000000000000000000000000dEaD` and the remainder directly to the
immutable farm vault. The vault receives odd-unit dust. Both final recipient
balance increases and the payer's total debit must match exactly; failure rolls
back payments, allowances and club state. The constructor rejects a vault equal
to zero, this contract, the burn sink, the payment token or the furniture.

Use a standard fixed-balance OG token: transfer taxes, extra sender fees,
rebasing/reflection behavior and dishonest balance reporting are unsupported.
SafeERC20 supports tokens returning no transfer boolean. Protocol payments never
remain in clubs. Unsolicited ERC-20 donations cannot be prevented or recovered.
The sink transfer does not reduce ERC-20 totalSupply. Vault revenue remains
subject to its unchanged 50% season-budget rule.

Place exactly one furniture unit with the existing transfer protocol:

```solidity
furniture.safeTransferFrom(
    from, address(clubs), furnitureId, 1,
    abi.encode(uint256(clubId), uint8(x), uint8(y), uint8(rot))
);
```

First, the owner configures `setFootprint(id, w, h, wall)`. Floor dimensions are
1..4 each; wall width is 1..4 and its height must be 1. An unused footprint can
change, including its wall flag. The first successful placement locks all its
fields globally and forever. Rejections do not lock it. IDs may include zero.
Every club can hold **at most one piece per furniture ID**, whether floor or
wall; a second copy reverts `AlreadyHasDesign`, including after a club transfer.
The same design can be placed in other clubs.

Floor pieces occupy a rectangle anchored at `(x,y)`. `rot` is 0..3; odd rotations
swap width and height. Pieces must fit inside the current size, avoid overlap,
and leave door tiles `(0,4)` and `(1,4)` empty. Floor occupancy uses one uint256
with the fixed stride **bit `y*16+x`**, so upgrades never reinterpret old tiles.

Wall placements interpret `rot` as side, `x` as start position, and require
`y=0`. Side 0 runs along `y=0`; side 1 runs along `x=0`. Each has its own uint32
bitmap, independent of the floor and the other side. A width-w piece covers
`[x,x+w)`, must fit the current wall, and cannot overlap a piece on that side.
**Side 1 position 4 is the door**: width 2 at starts 3 or 4 fails; start 5 fits.
Side 0 may cover position 4. Bad side/y/bounds revert `OutOfRoom`; overlap
reverts `TileTaken`. At level 4, **285 distinct one-wide pieces** can fill the
254 usable floor cells and 31 usable wall positions; the next placement reverts
`ClubFull`. This limit is tested using real transfers, without storage cheats.

Placement authenticates ERC-1155 **`from`** as the club holder or an approved
club account. Furniture's own transfer authorization is checked separately.
A furniture-approved operator can permanently place a holder's furniture into
that holder's club; club approval alone cannot spend another wallet's furniture.

Only the immutable furniture contract may call the single hook. Layout data
must have four ABI words with canonical uint8 coordinates/rotation; wrong
length or noncanonical values revert `BadPlacementData`. The batch hook rejects
all calls. The unchanged OpenZeppelin furniture routes singleton batches through
the single hook, where all placement checks still apply. Empty or multi-item
batches and direct minting into clubs fail.

Every placement emits `FurniturePlaced(clubId, furnitureId, x, y, rot, index,
wall)` with its zero-based index, followed by `MetadataUpdate(clubId)`.
Renderers can use:

| View | Result |
| --- | --- |
| `levelOf(clubId)`, `sizeOf(clubId)` | Current level and side length |
| `upgradePrice(currentLevel)` | Next level price; 0 at level 4; invalid levels revert `BadLevel` |
| `clubsMinted(pepeId)` | Whether the lifetime club mint right was used |
| `piecesOf(clubId)` | Ordered `Piece { furnitureId, x, y, rot, wall }[]` |
| `pieceCount(clubId)`, `hasDesign(clubId,id)` | Count and permanent design membership |
| `tileTaken(clubId,x,y)` | Floor occupancy; door tiles return false |
| `wallTaken(clubId,side,position)` | Wall occupancy; side-1 door returns false |
| `footprintOf(id)` | `(w,h,set,locked,wall)` |
| `tokenByIndex`, `tokenOfOwnerByIndex`, `totalSupply` | ERC-721 enumeration |
| `token`, `vault`, `price`, `furniture`, `pepes`, `delegates`, `saleOpen` | Immutable dependencies/pricing and sale control |

Club views reject nonexistent clubs with `NonexistentToken`; occupancy views
reject positions beyond the current room. A transfer carries the level, design
membership, layout and furniture unchanged; token-specific approvals clear.
There is no removal, relocation or furniture withdrawal. Owner powers remain
sale control, unused footprints, URI-prefix configuration/freeze and royalties.

`tokenURI(id)` returns `baseURI + decimal id + ".json"`. Prefix updates and
permanent freezing emit `BatchMetadataUpdate(0, uint256.max)`, including Pepe
ID zero. Freeze affects the URI prefix; placements, upgrades and unused
footprints remain available. It cannot freeze content hosted at a mutable URL.
Royalties start at 500 bps and may be set to 0..1000 bps with a nonzero receiver.
Marketplace enforcement remains external. Ownable2Step behavior is unchanged.

## Club deployment preparation

`launch.json` preserves the original five Sepolia applications and adds
MockSwarmPepe followed by OGClubClubs. The latter references the earlier MockOG,
farm vault, furniture and mock Pepes, uses `$owner` for owner and royalty
receiver, and uses the brief's delegate.xyz v2 address
`0x00000000000000447e69651d841bD8D104Bed493`. This address is configured from the
brief; no live registry availability check was performed here. Constructors
make no external calls and do not require dependency code on the empty chain.
The factory's deployment is constructor-only: **sale closed, metadata empty,
footprints unset**. The owner configures footprints/metadata and opens the sale.
Clubs consume neither of the raffle's first grants.

`script/DeployClubs.s.sol` provides:

| Script | Configuration | Sale after script |
| --- | --- | --- |
| `DeployClubsSepolia` | Deploys MockOG, furniture, farm vault, MockSwarmPepe and clubs. `OWNER`, optional `ROYALTY_RECEIVER` (defaults to owner), optional `FOOTPRINTS_JSON`. Mint price 100_000e18; upgrade prices 200_000e18, 400_000e18, 800_000e18; the specified real delegate.xyz v2 registry. Sepolia/local only. | Open |
| `DeployClubsMainnet` | Existing `OG_TOKEN`, `FARM_VAULT`, `FURNITURE`, `SWARM_PEPES`; `CLUB_PRICE`, `DELEGATE_REGISTRY`, comma-separated `UPGRADE_PRICES`; `DEPLOYER_KEY`, `OWNER`, `ROYALTY_RECEIVER`, optional `FOOTPRINTS_JSON`. Mainnet/local only. | Closed |

Mainnet `UPGRADE_PRICES` is
`200000000000000000000000,400000000000000000000000,800000000000000000000000`.
The script verifies **FARM_VAULT.token() == OG_TOKEN before broadcasting** and
deploys the constructor from **DEPLOYER_KEY**. **OWNER may be a Safe**; it is
passed directly into the constructor and never used as a broadcast signer.
The script prints footprint and sale-opening calldata for the owner to execute
through its normal authorization flow. It makes no owner configuration calls,
even for an EOA owner. Both scripts print addresses and ABI constructor args;
keys are never printed. This task did not execute either script's broadcast.

Sepolia retains its existing OWNER broadcaster for configuration and sale
opening. Use an authorized EOA signer for that script; a Safe can instead use
the constructor-only factory handoff and execute configuration separately.
**MockOG and MockSwarmPepe are Sepolia-only**, with local tests permitted.
MockSwarmPepe exposes `mint(pepeId)` to mint any unused ID to the caller.
Neither mock is deployed on mainnet.

Footprint JSON rows are `[furnitureId,width,height,wall]`, with **wall 0 or 1**.
Parsing checks unsigned values, dimensions, wall height, flag and duplicate IDs
before deployment. `script/club-footprints.json` supplies six **Sepolia sample
designs**: floor IDs 1..3 and wall IDs 4..6. They are editable test fixtures,
not a production catalogue. Supply the actual owner's catalogue for mainnet;
`[]` leaves all footprints unset. Pass contents via `FOOTPRINTS_JSON`, avoiding
changes to Foundry filesystem permissions. Local simulation example:

```sh
FOOTPRINTS_JSON="$(cat script/club-footprints.json)" \
  forge script script/DeployClubs.s.sol:DeployClubsSepolia \
  --chain-id 11155111 --sender "$OWNER"
```

The raffle's first `grantMinter` and `grantSpender` remain required owner steps.
Independent monitoring must draw each closed raffle while its target block hash
is available. See [ADAPTATION.md](ADAPTATION.md) for the review reproductions.

## Staking and points

Approve the staking contract, then call `stake(amount)`. The stake credited is
its actual token balance increase, so a fee deducted from a deposit cannot mint
extra stake or points. `unstake(amount)` is available immediately, including in
the same block as a stake. The immutable vault receives
`ceil(amount * 100 / 10000)` token units and the remaining units go to the staker.
A one-unit withdrawal pays one unit in fees; splitting withdrawals cannot avoid
fees. No points are awarded on unstaked balances.

For a balance held over `seconds`, accrual in point-wei is:

```text
balanceInTokenUnits * pointsPerTokenDay * seconds / (10**tokenDecimals * 86400)
```

`pointsOf(account)` includes pending accrual. Balances are checkpointed before
stake changes and point spending. Division remainders persist, including through
a full exit, so many small checkpoints have exactly the same result as one large
checkpoint. `spendPoints(account, amount)` is available only to authorized
spenders, and never makes an external token transfer. Points have no transfer,
approval, mint, or admin-adjustment function. Zero-point spends are harmless
checkpoints that retain fractions.

Each account occupies **two slots**: `uint128 balance`, `uint48 updatedAt` and
`uint80 remainder` packed together, plus `uint256 points`. The per-account stake
limit is `2**128 - 1` token units; the maximum rate is `2**96 - 1` point units per
token-day. Checked casts and full-precision multiplication prevent truncation and
intermediate overflow. The timestamp range extends to `2**48 - 1` seconds.

Token decimals (0–18, including OG/MockOG's 18) are read and fixed on the first
stake, not in the constructor. This supports ordinary fixed-balance ERC-20s with
stable metadata, including tokens returning no transfer boolean and fees deducted
from the transferred amount. Outbound transfers must debit exactly the requested
amount; extra sender-side fees revert atomically. Recipients of a taxed token
receive less after that token's own fee. Rebasing/reflection tokens and dishonest
balance reporting are unsupported. Unsolicited transfers to staking are surplus,
not stake or points, and cannot be swept. The balance-equals-total-staked invariant
applies to stake/unstake flows without unsolicited donations or rebases.

## Raffles, winning tickets and claims

The owner calls `createRaffle(opensAt, closesAt, pools)` with a nonempty pool list.
Opening must be at least `now + raffleNotice`; closing must be later. Each pool
has a display-only `uint8 tier`, positive point ticket price, a per-wallet ticket
cap (zero means unlimited), and one or more `{itemId, quantity}` prizes with
positive quantities. Item ID zero and repeated item IDs are supported. Caps are
per wallet **per pool per raffle**, not identity-based or Sybil resistant.
Quantities and total sold tickets per pool are at most `2**48 - 1`.

The terms and prize list cannot be edited. The owner can cancel only **before**
opening, when entry has not yet been possible. `enter(raffleId, poolId, tickets)`
works during `[opensAt, closesAt)`, spends `tickets * ticketPrice`, and appends an
entry for the sender. It records the contiguous half-open range `[first, end)` in
one storage slot, regardless of the ticket count. Ticket indices, pool indices,
entry indices and win indices start at zero; raffle IDs start at one. Tickets
cannot be transferred. Failed spending rolls back the range and cap update.

At or after closing, anyone calls `commitDraw(raffleId)` to target the block
**three blocks ahead**. Anyone may then call `draw(raffleId, header)` when
`target < block.number <= target + 256`. The entire canonical RLP header must
hash to `blockhash(target)`, and its decoded block number must equal the target.
Its `prevRandao` is stored as the seed, even when zero. Drawing never mints or
iterates over pools, tickets or entrants. After drawing the seed cannot change.

Let `W = min(prizes, ticketsSold)` for a pool. The valid wins are exactly
`k = 0 ... W-1`. `winningTicket(raffleId, pool, k)` evaluates an eight-round
Keccak Feistel permutation with cycle walking over ticket indices. `prizeOf`
evaluates a **separate, domain-separated permutation** over the expanded prize
positions and locates its item by binary search of cumulative quantities.
Thus each ticket wins at most once, wallets may win multiple times, and a pool
with enough tickets awards every listed quantity exactly. With fewer tickets,
the unused prize positions are random too; they are never minted.

Both permutations also bind the seed to the chain, raffle contract, raffle ID
and pool. Cycle walking uses the next power-of-four domain (less than four times
the requested size). It is an invertible pseudorandom selection without modulo
bias or a table of entrants. Walk length depends on the seed; it has a short
expected cost, not a fixed worst-case gas bound.

Anyone calls `claim(raffleId, pool, wins)`, where each win is `{k, entry}` and the
supplied entry must contain `winningTicket(k)`. It pays the entry wallet, never
the caller. Claimed win indices are recorded in a bitmap. Adjacent claims for
the same wallet share one `furniture.mintBatch`; grouping by wallet saves gas.
The on-chain work grows with the **wins submitted**, independently of entrant
and ticket counts (prize lookup is bounded by 128 lines). Read `Entered` events
or `getEntry` to locate ticket ranges off chain.

`claimTo(raffleId, pool, wins, to)` requires the caller to be the wallet of **every**
supplied entry and a nonzero recipient. It lets contract wallets redirect prizes.
Receiver or mint-permission failures roll back that transaction's claims and
mints; they remain retryable with the same results indefinitely. Submit subsets
to isolate a rejecting recipient. Claims are guarded against receiver reentrancy.

### Randomness and owner trust

This is the requested on-chain future-block randomness, not an external VRF.
Validators can influence/censor the target block and its prevRandao, and callers
can choose when to commit after closing. If **nobody draws** by target + 256,
anyone can re-commit beginning at target + 257, choosing a new future target.
An operator who withholds unfavorable draws, especially with censorship or no
independent keeper, can obtain another seed and bias results. Permissionless
drawing lets an independent party preserve an available outcome; it does not
eliminate these biases. Operators must monitor closed raffles and retrieve
headers inside the blockhash window. A finalized draw cannot be retargeted.

Owners cannot directly change stakes, point balances or drawn outcomes. They do
control spender authorization; an authorized spender can consume any account's
points, so later grants need scrutiny during their notice window. Furniture
minters can mint arbitrary IDs/quantities outside raffles. Revoking the raffle's
roles stops new point spending or prize delivery until reinstated, although
staking exits remain available and drawn claims retain their results. Prize
quantities are per pool, not global collection scarcity limits.

Furniture retains its original supply tracking, ERC-1155 transfers, metadata URI
format, permanent metadata freeze, and ERC-2981 royalties: initially 5%, owner
adjustable up to 10%. Its owner has no confiscation, privileged transfer or burn
right. Royalties are informational; marketplace enforcement is external.

## Farming vault

Unstake fees accumulate in `OGClubFarmVault`. The owner publishes a farming
allocation with `proposeSeason(root, total)`. Total must be positive and at most
`floor((tokenBalance - reserved) / 2)`. It is reserved immediately, claims open
three days later, and the next proposal must wait at least seven days after the
previous proposal even if that proposal was canceled.

Use sorted-pair OpenZeppelin Merkle trees (compatible with StandardMerkleTree)
and exactly this double-hashed leaf, with the types shown:

```solidity
keccak256(bytes.concat(keccak256(abi.encode(
    uint256(seasonId), address(account), uint256(amount)
))))
```

Season IDs begin at one; generate allocations for the correct ID. Include each
account once per season, since the contract pays only one allocation per account.
Keep the sum of allocations equal to `total`; a root alone cannot prove that sum,
and the contract refuses claims above the remaining season budget. Anyone may
submit `claim(seasonId, account, amount, proof)`, which pays only that account.
There is no relayer redirect. Zero allocations are valid but unnecessary.

`cancelSeason` is owner-only and works strictly before claims open. Claims are
valid during `[opensAt, opensAt + 90 days)`. At exactly `opensAt + 90 days`, claims
stop and the owner may call `releaseSeason` to unreserve the unpaid balance.
Cancellation and release **never transfer tokens**; the released funds become
eligible for later seasons. The owner has no other token-moving function.
The owner chooses recipients/root/total and could include itself in a valid
season: this remains a trust assumption subject to the budget and time limits.

## Header encoder and offline fixtures

`script/encode_header.py` takes an `eth_getBlockByNumber` JSON object or response
wrapper from a file or stdin. It encodes fields after `requestsHash` in the order
**blockAccessListHash, slotNumber** (slotNumber is an integer). It refuses gaps
and all unknown keys except explicitly allowlisted non-header RPC metadata.

```sh
python3 script/encode_header.py test/fixtures/sepolia-11921684.json
```

Sepolia block **11921684** has published hash
`0x0beea75b48cae0d6c13bf5a289c3f64ea9e4473bfacd2f9709d5c0a827e73629`.
The JSON and embedded RLP are checked both against that hash and through raffle
`draw`. Existing real Shanghai, Cancun and Prague fixtures remain tested. See
[test/fixtures/SOURCES.md](test/fixtures/SOURCES.md) for provenance. Always compare
`cast keccak` of the encoded header with the published hash before submitting it.

## Gas and EIP-8037

The project still targets Cancun. These are isolated-call measurements, followed
by a **storage-cost projection**, not a claim to execute the future fork.
[EIP-8037](https://eips.ethereum.org/EIPS/eip-8037) specifies 64 state bytes per
new storage slot and CPSB 1530: **97,920 state gas per fresh slot**, replacing
20,000 Cancun gas. The projected total adds **77,920 per durable fresh slot**
across all callees. Companion EIPs, transaction intrinsic/calldata gas and
refunds are not modeled; these are gross call costs, not receipt or gas-limit
estimates. ERC-20 transfers and ERC-1155 receiver behavior can change costs.

| Operation | Measured Cancun call gas | Fresh slots | EIP-8037 state gas | Storage-repriced call gas |
| --- | ---: | ---: | ---: | ---: |
| First-ever stake, fresh staker | 120,547 | 3 | 293,760 | 354,307 |
| Partial unstake, first checkpoint and first vault fee | 110,662 | 2 | 195,840 | 266,502 |
| First entry, 10 tickets, first point checkpoint | 155,364 | 4 | 391,680 | 467,044 |
| Draw, 23-field header | 74,312 | 1 | 97,920 | 152,232 |
| Claim 1 win to a fresh furniture wallet | 160,885 | 4 | 391,680 | 472,565 |
| Claim 10 distinct items to a fresh furniture wallet | 816,170 | 22 | 2,154,240 | 2,530,410 |

Measured with MockOG, 1e18 accrual, preapproved spending, and freshly granted
roles. Claim rows start with zero collection supply, mint to one EOA, and set the
first claim bitmap word. The ten-win pool has ten different IDs, so it creates
ten recipient balances and ten per-ID supply slots; repeated IDs cost less.
Draw uses the deterministic synthetic header in the gas test; real header sizes
change decoding costs. Permutation costs vary with the seed and domain sizes.
The two-slot staking account, one-slot entry and claim bitmap limit new state.
Reproduce both measurements and the asserted new-slot counts:

```sh
forge test --match-contract GasTest --isolate -vv
```

## Local checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0xe91e85dcb3160b998a496c6801541e7340f6ef9be3d10de0d176fe7f8ec66c2d forge test
forge fmt --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v
```

Tests cover accrual fractions and packed bounds, taxed/nonstandard tokens,
reentrancy, spender/minter lapse, raffle time/cap/header boundaries, retargeting,
permutation bijections, exact prize quantities, wrong entries and duplicate
claims, contract-wallet redirection, vault proofs and reserve deadlines. Stateful
invariants check stakes against token custody, independently integrated accrual
minus spending, and vault balances against all remaining reservations. The
retained furniture suite checks supply, transfer authorization, royalties and
frozen metadata. [ADAPTATION.md](ADAPTATION.md) records the changes and audit
reproductions.

Club tests cover holder/delegate eligibility, lifetime Pepe mint rights, room
levels, floor and wall geometry, design uniqueness, exact mint/upgrade payment
splitting and rollback, safe receivers,
reentrancy, real furniture integration, all rotations, authorization, permanent
custody, metadata, royalties and script/factory deployment. Fuzz tests compare
random placement sequences against an independent cell grid. Stateful club
invariants exercise minting, upgrades, rejected placements, sale changes, Pepe
transfers/remint attempts and club transfers,
checking payment conservation, zero protocol OG custody, and an exact match
between per-ID furniture holdings and all clubs' ordered layouts.
