// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PepeMock, DelegateRegistryMock} from "./helpers/PepeMocks.sol";
import {TestToken} from "./helpers/TokenMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A closed economy and an independent authorization model. No production view decides whether a call
/// should succeed. Only the mock registry's exact ERC721/rights=0 scope is enabled in this campaign.
contract ClubDelegationHandler is Test {
    uint256 public constant MINT_PRICE = 17;
    uint256 public constant INITIAL_BALANCE = 2000;
    uint256 public constant PEPE_COUNT = 6;
    uint256 public constant MISSING_PEPE = 99999;
    TestToken public immutable token;
    PepeMock public immutable pepes;
    DelegateRegistryMock public immutable registry;
    OGClubClubs public immutable clubs;
    address public immutable admin;
    address[4] public actors;
    uint256[6] public ids;
    bool public saleOpen = true;

    mapping(uint256 => address) public pepeOwner;
    mapping(uint256 => address) public clubOwner;
    mapping(uint256 => address) public clubApproved;
    mapping(address => mapping(address => bool)) public clubOperator;
    mapping(address => mapping(address => mapping(uint256 => bool))) public delegated;
    mapping(uint256 => uint8) public level;
    mapping(uint256 => uint256) public mintCount;
    mapping(address => uint256) public balance;
    mapping(address => uint256) public paidBy;
    uint256 public minted;
    uint256 public paid;
    uint256 public burned;
    uint256 public revenue;
    uint256 public delegatedMints;
    uint256 public operatorUpgrades;
    uint256 public paymentRejections;
    uint256 public authorizationRejections;

    constructor(TestToken token_, PepeMock pepes_, DelegateRegistryMock registry_, OGClubClubs clubs_, address admin_) {
        token = token_;
        pepes = pepes_;
        registry = registry_;
        clubs = clubs_;
        admin = admin_;
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("delegation actor ", vm.toString(i)));
            token.mint(actors[i], INITIAL_BALANCE);
            balance[actors[i]] = INITIAL_BALANCE;
        }
        ids = [uint256(0), 11, 1023, uint256(1) << 128, uint256(1) << 255, type(uint256).max];
        for (uint256 i; i < PEPE_COUNT; ++i) {
            pepeOwner[ids[i]] = actors[i % 4];
            pepes.mint(pepeOwner[ids[i]], ids[i]);
        }
    }

    function priceAt(uint8 currentLevel) public pure returns (uint256) {
        if (currentLevel == 0) return MINT_PRICE;
        if (currentLevel == 1) return 101;
        if (currentLevel == 2) return 202;
        if (currentLevel == 3) return 405;
        return 0;
    }

    function delegate(uint8 idSeed, uint8 holderSeed, uint8 hotSeed, uint8 scopeSeed, bool enabled) public {
        uint256 id = ids[idSeed % PEPE_COUNT];
        address holder = actors[holderSeed % 4];
        address hot = actors[hotSeed % 4];
        uint256 scope = scopeSeed % 3;
        address collection = scope == 2 ? address(clubs) : address(pepes);
        bytes32 rights = scope == 1 ? keccak256("unrelated rights") : bytes32(0);
        vm.prank(holder);
        registry.delegateERC721(hot, collection, id, rights, enabled);
        if (scope == 0) delegated[holder][hot][id] = enabled;
    }

    function transferPepe(uint8 idSeed, uint8 toSeed) public {
        uint256 id = ids[idSeed % PEPE_COUNT];
        address from = pepeOwner[id];
        address to = actors[toSeed % 4];
        vm.prank(from);
        pepes.transferFrom(from, to, id);
        pepeOwner[id] = to;
    }

    /// @dev ERC721 transfer approval grants no mint privilege; callers still need a delegate.xyz grant.
    function approvePepe(uint8 idSeed, uint8 spenderSeed, bool all, bool enabled) external {
        uint256 id = ids[idSeed % PEPE_COUNT];
        address holder = pepeOwner[id];
        address spender = actors[spenderSeed % 4];
        if (spender == holder) return;
        vm.prank(holder);
        if (all) pepes.setApprovalForAll(spender, enabled);
        else pepes.approve(enabled ? spender : address(0), id);
    }

    function setSale(bool open) public {
        vm.prank(admin);
        clubs.setSaleOpen(open);
        saleOpen = open;
    }

    function transferClub(uint8 idSeed, uint8 toSeed) external {
        uint256 id = ids[idSeed % PEPE_COUNT];
        if (level[id] == 0) return;
        address holder = clubOwner[id];
        address to = actors[toSeed % 4];
        vm.prank(holder);
        clubs.transferFrom(holder, to, id);
        clubOwner[id] = to;
        clubApproved[id] = address(0);
    }

    function approveClub(uint8 idSeed, uint8 spenderSeed, bool all, bool enabled) public {
        uint256 id = ids[idSeed % PEPE_COUNT];
        if (level[id] == 0) return;
        address holder = clubOwner[id];
        address spender = actors[spenderSeed % 4];
        if (spender == holder) return;
        vm.prank(holder);
        if (all) {
            clubs.setApprovalForAll(spender, enabled);
            clubOperator[holder][spender] = enabled;
        } else {
            clubs.approve(enabled ? spender : address(0), id);
            clubApproved[id] = enabled ? spender : address(0);
        }
    }

    /// @dev Emptying a wallet makes real insufficient-balance failures reachable without token storage cheats.
    function moveBudget(uint8 fromSeed, uint8 toSeed, uint256 amountSeed, bool all) external {
        address from = actors[fromSeed % 4];
        address to = actors[toSeed % 4];
        if (from == to) return;
        uint256 amount = all ? balance[from] : bound(amountSeed, 0, balance[from]);
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private {
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        balance[from] -= amount;
        balance[to] += amount;
    }

    function mint(uint8 idSeed, uint8 payerSeed, uint8 paymentMode) public {
        uint256 slot = idSeed % (PEPE_COUNT + 1);
        uint256 id = slot == PEPE_COUNT ? MISSING_PEPE : ids[slot];
        address payer = actors[payerSeed % 4];
        bytes4 validationError;
        if (!saleOpen) {
            validationError = OGClubClubs.SaleClosed.selector;
        } else if (mintCount[id] != 0) {
            validationError = OGClubClubs.AlreadyMinted.selector;
        } else if (slot == PEPE_COUNT) {
            validationError = IERC721Errors.ERC721NonexistentToken.selector;
        } else if (payer != pepeOwner[id] && !delegated[pepeOwner[id]][payer][id]) {
            validationError = OGClubClubs.NotPepeHolder.selector;
        }
        if (!_tryPayment(payer, MINT_PRICE, paymentMode, validationError, abi.encodeCall(clubs.mintClub, (id)))) {
            return;
        }
        if (payer != pepeOwner[id]) ++delegatedMints;
        clubOwner[id] = payer;
        level[id] = 1;
        ++mintCount[id];
        ++minted;
    }

    function upgrade(uint8 idSeed, uint8 payerSeed, uint8 paymentMode) public {
        uint256 slot = idSeed % (PEPE_COUNT + 1);
        uint256 id = slot == PEPE_COUNT ? MISSING_PEPE : ids[slot];
        address payer = actors[payerSeed % 4];
        address holder = clubOwner[id];
        uint8 oldLevel = level[id];
        bytes4 validationError;
        if (oldLevel == 0) {
            validationError = OGClubClubs.NonexistentToken.selector;
        } else if (payer != holder && payer != clubApproved[id] && !clubOperator[holder][payer]) {
            validationError = OGClubClubs.NotClubOwner.selector;
        } else if (oldLevel == 4) {
            validationError = OGClubClubs.MaxLevel.selector;
        }
        uint256 cost = oldLevel == 0 ? 0 : priceAt(oldLevel);
        if (!_tryPayment(payer, cost, paymentMode, validationError, abi.encodeCall(clubs.upgradeClub, (id)))) return;
        if (payer != holder) ++operatorUpgrades;
        level[id] = oldLevel + 1;
    }

    function _tryPayment(address payer, uint256 cost, uint8 mode, bytes4 validationError, bytes memory callData)
        private
        returns (bool)
    {
        uint256 allowance = mode % 3 == 2 ? type(uint256).max : (mode % 3 == 1 && cost != 0 ? cost - 1 : cost);
        vm.prank(payer);
        token.approve(address(clubs), allowance);
        bool solvent = balance[payer] >= cost;
        bool approved = allowance >= cost;
        bool expected = validationError == bytes4(0) && solvent && approved;
        bytes32 beforeState = snapshot();
        vm.prank(payer);
        (bool ok, bytes memory result) = address(clubs).call(callData);
        assertEq(ok, expected, "payment/authorization model disagrees with call outcome");
        if (!ok) {
            assertEq(snapshot(), beforeState, "failed action changed balances, allowances, mint rights or ownership");
            if (validationError != bytes4(0)) {
                assertEq(bytes4(result), validationError);
                if (
                    validationError == OGClubClubs.NotClubOwner.selector
                        || validationError == OGClubClubs.NotPepeHolder.selector
                ) {
                    ++authorizationRejections;
                }
            } else {
                assertTrue(
                    (!approved && bytes4(result) == IERC20Errors.ERC20InsufficientAllowance.selector)
                        || (!solvent && bytes4(result) == IERC20Errors.ERC20InsufficientBalance.selector),
                    "unexpected payment failure"
                );
                ++paymentRejections;
            }
            return false;
        }
        balance[payer] -= cost;
        paidBy[payer] += cost;
        paid += cost;
        burned += cost / 2;
        revenue += cost - cost / 2;
        assertEq(token.allowance(payer, address(clubs)), allowance == type(uint256).max ? allowance : allowance - cost);
        return true;
    }

    /// @dev Hash every modeled account and Pepe/club, so a failed call cannot silently modify a different id.
    function snapshot() public view returns (bytes32 state) {
        state = keccak256(
            abi.encode(
                clubs.totalSupply(),
                clubs.saleOpen(),
                token.totalSupply(),
                token.balanceOf(clubs.BURN_ADDRESS()),
                token.balanceOf(clubs.vault()),
                token.balanceOf(address(clubs))
            )
        );
        for (uint256 i; i < 4; ++i) {
            state = keccak256(
                abi.encode(
                    state,
                    token.balanceOf(actors[i]),
                    token.allowance(actors[i], address(clubs)),
                    clubs.balanceOf(actors[i])
                )
            );
        }
        for (uint256 i; i < PEPE_COUNT; ++i) {
            uint256 id = ids[i];
            bool exists = clubs.clubsMinted(id);
            state = keccak256(abi.encode(state, id, exists, pepes.ownerOf(id)));
            if (exists) {
                state = keccak256(
                    abi.encode(state, clubs.levelOf(id), clubs.ownerOf(id), clubs.getApproved(id), clubs.piecesOf(id))
                );
            }
        }
    }

    /// @dev Run only after the random history: restore budgets by ordinary transfers, then complete every club.
    /// This detects permanently consumed mint rights or unusable upgrade states following failed payments.
    function finish() external {
        setSale(true);
        for (uint8 slot; slot < PEPE_COUNT; ++slot) {
            uint256 id = ids[slot];
            if (level[id] == 0) {
                _ensureBudget(pepeOwner[id], MINT_PRICE);
                mint(slot, _actorIndex(pepeOwner[id]), 0);
            }
            while (level[id] < 4) {
                _ensureBudget(clubOwner[id], priceAt(level[id]));
                upgrade(slot, _actorIndex(clubOwner[id]), 0);
            }
        }
    }

    function _ensureBudget(address payer, uint256 cost) private {
        for (uint256 i; i < 4 && balance[payer] < cost; ++i) {
            address donor = actors[i];
            if (donor == payer) continue;
            uint256 deficit = cost - balance[payer];
            _move(donor, payer, balance[donor] < deficit ? balance[donor] : deficit);
        }
        assertGe(balance[payer], cost, "closed economy unexpectedly exhausted");
    }

    function _actorIndex(address actor) private view returns (uint8) {
        for (uint8 i; i < 4; ++i) {
            if (actors[i] == actor) return i;
        }
        revert("actor missing from model");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract ClubsDelegationInvariantTest is Test {
    TestToken internal token;
    PepeMock internal pepes;
    DelegateRegistryMock internal registry;
    OGClubClubs internal clubs;
    ClubDelegationHandler internal handler;

    function setUp() public {
        token = new TestToken(18);
        pepes = new PepeMock();
        registry = new DelegateRegistryMock();
        OGClubFurniture furniture = new OGClubFurniture(address(this), address(this));
        OGClubFarmVault vault = new OGClubFarmVault(token, address(this));
        clubs = new OGClubClubs(
            token,
            address(vault),
            17,
            IERC1155(address(furniture)),
            address(this),
            address(this),
            pepes,
            registry,
            OGClubClubs.UpgradePrices(101, 202, 405)
        );
        clubs.setSaleOpen(true);
        handler = new ClubDelegationHandler(token, pepes, registry, clubs, address(this));
        // Non-vacuous successful delegation, operator upgrade, revoked delegation and late payment failure.
        handler.delegate(0, 0, 1, 0, true);
        handler.mint(0, 1, 0);
        handler.approveClub(0, 2, false, true);
        handler.upgrade(0, 2, 0);
        handler.upgrade(0, 2, 1);
        handler.delegate(2, 2, 3, 0, true);
        handler.delegate(2, 2, 3, 0, false);
        handler.mint(2, 3, 0);
        handler.mint(1, 1, 0);
        handler.transferPepe(0, 3);
        handler.mint(0, 3, 0);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.upgrade.selector;
        selectors[2] = handler.delegate.selector;
        selectors[3] = handler.transferPepe.selector;
        selectors[4] = handler.transferClub.selector;
        selectors[5] = handler.approveClub.selector;
        selectors[6] = handler.approvePepe.selector;
        selectors[7] = handler.moveBudget.selector;
        selectors[8] = handler.setSale.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EachPepeMintsOnceAndOnlyAuthorizedCallersPay() public view {
        assertEq(clubs.totalSupply(), handler.minted());
        assertEq(clubs.saleOpen(), handler.saleOpen());
        assertFalse(clubs.clubsMinted(handler.MISSING_PEPE()));
        uint256 expectedPaid;
        for (uint256 i; i < handler.PEPE_COUNT(); ++i) {
            uint256 id = handler.ids(i);
            uint8 level = handler.level(id);
            assertEq(pepes.ownerOf(id), handler.pepeOwner(id));
            assertEq(clubs.clubsMinted(id), level != 0);
            assertEq(handler.mintCount(id), level == 0 ? 0 : 1);
            if (level == 0) {
                try clubs.ownerOf(id) returns (address) {
                    revert("unminted Pepe unexpectedly has a club");
                } catch (bytes memory err) {
                    assertEq(bytes4(err), IERC721Errors.ERC721NonexistentToken.selector);
                }
                continue;
            }
            assertLe(level, 4);
            assertEq(clubs.levelOf(id), level);
            assertEq(clubs.sizeOf(id), 8 + 2 * uint256(level));
            assertEq(clubs.ownerOf(id), handler.clubOwner(id));
            assertEq(clubs.getApproved(id), handler.clubApproved(id));
            for (uint8 l; l < level; ++l) {
                expectedPaid += handler.priceAt(l);
            }
        }
        assertEq(handler.paid(), expectedPaid);
        uint256 wallets;
        uint256 actorPayments;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.balance(actor));
            wallets += token.balanceOf(actor);
            actorPayments += handler.paidBy(actor);
            uint256 owned;
            for (uint256 j; j < handler.PEPE_COUNT(); ++j) {
                if (handler.clubOwner(handler.ids(j)) == actor) ++owned;
            }
            assertEq(clubs.balanceOf(actor), owned);
            for (uint256 j; j < owned; ++j) {
                assertEq(handler.clubOwner(clubs.tokenOfOwnerByIndex(actor, j)), actor);
            }
            for (uint256 j; j < 4; ++j) {
                address operator = handler.actors(j);
                assertEq(clubs.isApprovedForAll(actor, operator), handler.clubOperator(actor, operator));
            }
        }
        for (uint256 i; i < clubs.totalSupply(); ++i) {
            uint256 id = clubs.tokenByIndex(i);
            assertEq(handler.mintCount(id), 1);
            for (uint256 j; j < i; ++j) {
                assertTrue(id != clubs.tokenByIndex(j), "duplicate enumeration entry");
            }
        }
        assertEq(token.balanceOf(address(clubs)), 0);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), handler.burned());
        assertEq(token.balanceOf(clubs.vault()), handler.revenue());
        assertEq(handler.burned() + handler.revenue(), expectedPaid);
        assertEq(actorPayments, expectedPaid);
        assertEq(wallets + expectedPaid, 4 * handler.INITIAL_BALANCE());
        assertEq(token.totalSupply(), 4 * handler.INITIAL_BALANCE());
    }

    function afterInvariant() external {
        assertGt(handler.delegatedMints(), 0);
        assertGt(handler.operatorUpgrades(), 0);
        assertGt(handler.authorizationRejections(), 0);
        assertGt(handler.paymentRejections(), 0);
        handler.finish();
        invariant_EachPepeMintsOnceAndOnlyAuthorizedCallersPay();
        assertEq(clubs.totalSupply(), handler.PEPE_COUNT());
        for (uint256 i; i < handler.PEPE_COUNT(); ++i) {
            assertEq(clubs.levelOf(handler.ids(i)), 4);
        }
    }

    function test_DelegationAndPepeOwnershipDoNotConferControlOfAnAlreadyMintedClub() public {
        // setUp minted club #0 to actor 1 via actor 0's delegation, then moved Pepe #0 to actor 3.
        handler.upgrade(0, 0, 0);
        handler.upgrade(0, 3, 0);
        handler.delegate(0, 3, 0, 0, true);
        handler.upgrade(0, 0, 0);
        handler.mint(0, 0, 0);
        assertEq(clubs.levelOf(0), 2);
        assertEq(clubs.ownerOf(0), handler.actors(1));

        handler.transferClub(0, 3);
        handler.upgrade(0, 2, 0); // Its former token approval was cleared by the transfer.
        assertEq(clubs.levelOf(0), 2);
        handler.upgrade(0, 3, 0);
        assertEq(clubs.levelOf(0), 3);
        handler.approveClub(0, 0, true, true);
        handler.upgrade(0, 0, 0);
        assertEq(clubs.levelOf(0), 4);
        invariant_EachPepeMintsOnceAndOnlyAuthorizedCallersPay();
    }

    function test_TransferOfUnmintedPepeRequiresADelegationFromTheNewHolder() public {
        handler.delegate(2, 2, 0, 0, true);
        handler.transferPepe(2, 3);
        handler.mint(2, 0, 0);
        assertFalse(clubs.clubsMinted(1023));
        handler.delegate(2, 3, 0, 0, true);
        handler.mint(2, 0, 0);
        assertEq(clubs.ownerOf(1023), handler.actors(0));
        assertEq(pepes.ownerOf(1023), handler.actors(3));
        invariant_EachPepeMintsOnceAndOnlyAuthorizedCallersPay();
    }
}
