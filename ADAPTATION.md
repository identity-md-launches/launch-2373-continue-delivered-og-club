# OG Club launch adaptation

This revision continues the delivered clubs project at
`292e20dec8afa05dc98367c8a9f47bd39a4b66a5`. Only OGClubClubs changes among the
existing application contracts. Furniture, farm vault, staking, raffle, MockOG,
both libraries and the original raffle deployment script retain their behavior
and source. Build configuration and vendored dependencies are unchanged. No
packages, submodules, invented production addresses, keys or initialization machinery
were added. No signing, broadcasting or live deployment was performed.

The supplied protected factory/ownership tests and pinned security inputs were
read. Constructors remain nonpayable and do not call dependencies or require
code at their addresses. Owners and royalty recipients are explicit constructor
arguments, never the factory or tx.origin. All library calls remain internal.
The seven-contract Sepolia manifest fits the factory's eight-contract limit.

## Changes and reasons

| Files | Change and requirement |
| --- | --- |
| `src/OGClubClubs.sol` | Replaced sequential/gifting mint entry points with `mintClub(pepeId)`. The current Swarm Pepe holder or its delegate.xyz v2 delegate pays and receives exactly that ID. Immutable `pepes` is nonzero; immutable `delegates` may be zero to disable delegation. Lifetime `clubsMinted` state survives both kinds of NFT transfer. `ClubMinted` includes pepeId. |
| `src/interfaces/IDelegateRegistry.sol` | Minimal local declaration of the exact v2 ERC-721 authorization query from the brief, including rights=0. No new dependency or external library is needed. |
| `src/OGClubClubs.sol` | Added levels 1..4, holder/operator paid upgrades, immutable positive prices, level/size/next-price views, `MaxLevel`, `ClubUpgraded` and metadata updates. Mint and upgrade share the unchanged direct-transfer split and exact final receipt/payer-debit checks. Sale control continues to gate new mints only. |
| `src/OGClubClubs.sol`, `launch.json` | Used the factory's supported static `UpgradePrices` struct (`level2`, `level3`, `level4`) to represent the requested three-price array. The constructor has nine top-level ABI inputs and eleven flattened static fields. A fixed array is not among the supplied factory reference's supported types; expanding a uint256[3] argument into three manifest entries caused the prior rejection. The tuple's fields are flattened in declaration order as the reference requires, and stored in three Solidity immutable fields. No price setter exists. |
| `src/OGClubClubs.sol` | Replaced every floor stride/bound with fixed stride 16 and per-club size. Door bits are 64/65. Added independent uint32 occupancy for both back walls, wall dimensions/placement validation, wall flag in pieces/events/footprint views, and a globally locked wall flag. Room growth preserves all old coordinates. Added wall occupancy view for renderers and tests. |
| `src/OGClubClubs.sol` | Added permanent per-club design membership and `AlreadyHasDesign`. Duplicate-design rejection also applies at full capacity. Set the reachable maximum to 285 (254 floor + 31 wall). Replaced empty/canonical-decoder failures with `BadPlacementData`, including wrong length and uint8 words exceeding 255. |
| `src/OGClubClubs.sol` | Rejects vault aliases with the burn sink, payment token or furniture, retaining the existing self-vault rejection and exact payment checks. Full-range metadata events now begin at zero because Pepe ID zero can exist. Existing custody, ERC-721 approvals/enumeration, ownership, URI freeze and royalty behavior is preserved. |
| `src/mocks/MockSwarmPepe.sol` | Added the requested Sepolia mock ERC-721 with public `mint(pepeId)` to the caller. There is no admin, external constructor dependency or initializer. Duplicate IDs fail through ERC-721. |
| `script/DeployClubs.s.sol` | Sepolia additionally deploys mock Pepes, uses the supplied real v2 registry address and 200_000e18/400_000e18/800_000e18 upgrade prices. JSON gains a numeric wall flag. Both scripts print addresses and ABI constructor arguments. |
| `script/DeployClubs.s.sol` | Mainnet takes SWARM_PEPES, DELEGATE_REGISTRY and a three-value comma-separated UPGRADE_PRICES from env. It checks FARM_VAULT.token() against OG_TOKEN before starting broadcast, deploys using DEPLOYER_KEY, passes OWNER directly to the constructor, and leaves owner-only footprint/sale calls as printed calldata. This works when OWNER is a Safe; no Safe address is used as broadcaster. |
| `script/club-footprints.json` | Added six Sepolia sample rows with the wall column, including three wall widths. These are explicitly testnet examples, not a claimed mainnet catalogue. Mainnet accepts the owner's actual rows or an empty owner-settable catalogue. |
| `launch.json` | Retained the original five deployments and their constructor values; inserted MockSwarmPepe before clubs, added Pepe/registry/static-price fields, and updated notes. Both mocks are Sepolia-only. Raffle first grants remain explicit owner steps. The manifest is supplied because the task explicitly requests it, overriding the quoted background's deferral. |
| `README.md`, `test/ADDITIONAL_COVERAGE.md` | Documents eligibility, IDs, delegation, levels/prices, floor/wall ABI and geometry, design uniqueness, errors/views/events, factory tuple encoding, immutable custody, operator rights, Safe deployment, Sepolia-only mocks, catalogue samples and supplied fuzz seed. Existing unrelated protocol documentation is preserved. |
| `test/helpers/ClubsTestBase.sol`, `test/helpers/PepeMocks.sol` | Added offline Pepe ownership and registry fixtures. Existing fixtures supply explicit Pepe eligibility and upgrade prices. Test-only keys/addresses remain confined to tests; production dependencies come from manifest references or the operator's env. |
| `test/OGClubClubs.t.sol`, `test/ClubsAdversarial.t.sol`, `test/ClubsPlacement.t.sol` | Adapted existing tests to Pepe IDs, wall-aware footprint APIs and distinct designs. Retained payment failure/reentrancy, authorization, custody, ownership, royalty, metadata, receiver and geometry coverage. Replaced the synthetic unreachable cap test with 285 real distinct placements. Added constructor-alias and named malformed-data regressions. |
| `test/ClubsLaunchRules.t.sol` | Added holder/delegate/revocation/disabled-registry tests; rights/collection/current-holder binding; repeat mint after both NFT transfers; sparse/zero/max IDs; positive prices; exact upgrades/events/operator payment, receipt rollback and reentrancy; unchanged old tiles and newly available front cells; both walls/widths/end bounds/door/overlap/y/side rules; flag locks and per-club design uniqueness through transfer. |
| `test/ClubsInvariant.t.sol` | Uses an independent cell-by-cell floor/wall model. Fuzzes levels, dimensions, positions, rotations and repeated designs, comparing every occupancy view after successes and failures. Stateful sequences include sparse-ID minting, both NFT transfers, repeat mint attempts, upgrades, sale changes and placement. Checks lifetime mint counts, recorded-payment conservation, zero protocol OG custody and exact furniture custody. |
| `test/ClubsAdversarialInvariant.t.sol` | Retained the independent multi-actor approval/operator/footprint-change model, updating its Pepe eligibility and duplicate-design oracle. This complements the new level/wall model without changing pre-existing protocol invariants. |
| `test/ClubsDeployment.t.sol` | Tests Sepolia dependencies/prices/registry, mock public mint, JSON flags, mainnet vault mismatch before deployment, deployment by a separate key with contract owner, owner configuration handoff, empty-chain CREATE2, flat manifest word/tuple equivalence and bounded opcode-safe runtime. |
| `test/test_launch.py` | Validates the seven entries against compiler ABIs, flattening supported static tuples and explicitly rejecting constructor arrays. Checks argument order, counts, owner/dependency references, Sepolia-only labeling and preserved raffle handoff. This rejects the previous fixed-array/eleven-word mismatch. |
| `test/ImportedAudit.t.sol` | Only adapts club construction and Pepe eligibility in the earlier audit reproductions. Existing raffle-role, MockOG and draw-window observations remain covered and unchanged. |

## Imported review findings: reproduction and disposition

Before editing OGClubClubs or its script, five scratch tests ran against the
original implementation and passed, confirming all six low findings. Their
assertions covered the original unwanted behavior; permanent delivered tests
now assert the corrected behavior. No low finding was dismissed as unreproduced.
The supplied seventh item was informational, not a failure in the original.

| Finding | Reproduction and resolution |
| --- | --- |
| `642d342a02e060d86bdba79fb4dfe0acf9befc4a4c842e7c4c7ca58fbff92b3a` | Original burn-sink vault deployed, then mint reverted `UnexpectedTokenDebit`. Constructor now rejects it. Covered by `test_ConstructorRejectsBurnTokenAndFurnitureVaultAliases`. |
| `3ec8e3eba66258f883538c2b81233cc933e2cf5777fb6b636b0702ae82c157ea` | Original token and furniture vault aliases accepted a price-10 mint and each received five unrecoverable units. Both now revert during construction, covered by the same alias test. |
| `413e7cfab61a9849e69b891f06ac417a03a43a5820d42cb168e59349b144363e` | Original mainnet helper accepted a vault for a second ERC-20; the OG payment reached that vault while its configured token balance stayed zero. `test_MainnetScriptRejectsWrongVaultTokenBeforeDeploying` checks the mismatch error and unchanged deployer nonce/no deployed code. |
| `803caf33f74b6dba0bfbf3c576f9fa3312d0bd72b5f9568afc75bc89a7d60c94` | Original 129-byte placement surfaced `ERC1155InvalidReceiver(clubs)`. Both wrong-length and noncanonical-word cases now bubble `BadPlacementData`; placement/adversarial tests verify custody, layout and footprint locks stay unchanged. |
| `f3c8a53f94e3aaf3329a1c7bdd12dacadd10fa5b7af12ad4454e9b2bce68e0f2` | The original script's resulting CREATE address matched OWNER's nonce, confirming OWNER was its broadcaster; its owner-only setup calls also required that identity. A Safe has no EOA signing key. The regression checks CREATE from a separate test deployer key, a contract as owner, unconfigured/closed state, and later owner calls. No live Safe/key was needed or used. |
| `ab2524ab2b1ae9e0e84ede568fc3a5cbde891637cbdccbb83424baa60a59e025` | Original room filled 98 floor cells with no way to reach MAX_PIECES=100; the next attempt returned a geometry error. `test_ClubFullIsReachedBy285DistinctRealPieces` now fills 254 floor cells plus 31 wall positions and rejects a new design as ClubFull. |
| `88fb1d026f3d9ca055ce96c814dd734a54a269ed014a8e3f8400f50f2ef9c431` | Not a defect in the delivered 10x10 layout: the original three stride sites agreed. All are updated together. Fixed-stride regression places (4,6), rejects actual door cells at every level, and preserves prior tiles through upgrades; fuzz/stateful models check all occupied positions. |

## Preserved handoff and limits

- The raffle's FIRST `grantMinter(raffle)` and FIRST `grantSpender(raffle)` are
  still owner operations. Neither club constructor nor script consumes them.
  The factory performs no post-construction initialization calls.
- Sepolia script owner actions still use its existing EOA OWNER broadcast flow.
  A Safe can use the factory handoff or the mainnet script's separated deployer
  flow, then configure clubs through its own authorization. Mainnet stays closed.
- The supplied delegate.xyz registry address is configured, not fabricated. No
  live-chain code or delegation check was made here. Direct holders work without
  registry calls; the deployment service should confirm the configured registry
  exists before advertising delegated minting.
- MockOG's unrestricted mint remains unchanged and Sepolia-only. MockSwarmPepe
  is likewise a public testnet faucet. Mainnet deploys neither mock.
- Furniture operators can permanently place a holder's furniture. Club operators
  can upgrade at their own expense. Ownership/admin powers otherwise remain the
  requested sale, footprint, URI and royalty settings, with two-step transfer.
- The protocol's zero-OG-custody invariant excludes unsolicited donations,
  rebases and dishonest token implementations. No recovery sweep was added.
- Existing singleton ERC-1155 batch behavior and raffle draw-window/retarget
  behavior are preserved and documented; neither is redesigned by this work.
- No Slither, Mythril, explorer verification, RPC fork or live deployment is
  claimed. The local tests exercise the supplied protected constructor/owner/
  runtime properties without launch-service environment inputs.

## Validation

The local-check repair shortens `launch.json` notes from 5,060 to 3,191 characters,
below the manifest's 4,000-character maximum. Deployment entries, constructor
arguments, Sepolia-only mock labels and the raffle's owner handoff are preserved.
`test/test_launch.py` now checks the notes type and length as well as the ABI.

The reported test run stopped at 600 seconds without a failed assertion. To
reduce repeated assertion overhead, `test/ClubsInvariant.t.sol` now reads every
floor/wall occupancy view into a complete board and compares its hash with both
the independent model and the board reconstructed from pieces. The handler
returns its whole model hash in one call instead of one call per cell. These
comparisons still run after every fuzz placement and every stateful action;
the geometry, door, design, custody and payment assertions are retained. No
application code, fuzz-run count, invariant depth or build setting is changed
by this repair. `test/ClubsAdversarialInvariant.t.sol` uses the same complete-board
comparison for its independent level-one approval/operator model, preserving
every tile observation after every action and its 64 runs of depth 64.

The exact supplied fuzz seed is
`0xe91e85dcb3160b998a496c6801541e7340f6ef9be3d10de0d176fe7f8ec66c2d`.
No configuration, fuzz-run count or invariant-depth reduction was made.
The final checks use the repository's own configuration. No RPC, network fetch,
external account, env file or launch-service credentials are required.

| Check | Result |
| --- | --- |
| `forge build` | Passed with Solidity 0.8.26 and the unchanged configuration. |
| Seeded club invariant campaigns | The level/wall handler completed 128 runs / 8,192 calls with zero unexpected reverts; the approval/footprint handler completed 64 runs / 4,096 calls with zero unexpected reverts. |
| Seeded complete `forge test` | 219 passed, zero failures, zero skipped across 30 suites in 483.50 seconds (491.01 seconds including compilation), below the local check's 600-second limit. The final level/wall campaign completed all 8,192 calls with zero unexpected reverts. |
| `forge fmt --check` | Passed. |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v` | All six checks passed, including static-tuple manifest/ABI validation. |
| `git diff --check` | Passed. |
| SHA-256 baseline comparison | The only changed existing source/config/dependency file is `src/OGClubClubs.sol`. Other existing application sources, libraries, vendored dependencies, protected build files and the original raffle deployment script match the baseline. |
| Runtime / factory | OGClubClubs runtime is 15,260 bytes, below 24,576. Empty-chain CREATE2, manifest-word decoding, owner assignment, and the protected reachable-opcode rule are exercised locally. |

Forge's lint notices include existing-project warnings and reviewed notices on
clubs: vault zero validation is delegated to `_nonzero`, mint events follow the
safe receiver callback as before, and bitmap/coordinate casts have explicit
bounds. The reentrancy and malformed-coordinate tests cover those paths. These
notices are not compiler or test failures.
