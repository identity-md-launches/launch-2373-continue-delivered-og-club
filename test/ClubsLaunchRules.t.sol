// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {DelegateRegistryMock} from "./helpers/PepeMocks.sol";
import {TestToken} from "./helpers/TokenMocks.sol";
import {ClubReceiptToken} from "./OGClubClubs.t.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ClubsPepeTest is ClubsTestBase {
    function _withRegistry(IDelegateRegistry registry) private returns (OGClubClubs c) {
        c = new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            registry,
            OGClubClubs.UpgradePrices(201, 401, 801)
        );
        c.setSaleOpen(true);
        vm.prank(alice);
        token.approve(address(c), 10 * PRICE);
        vm.prank(bob);
        token.approve(address(c), 10 * PRICE);
    }

    function test_OnlyPepeHolderOrExplicitDelegateMayMintAndCallerReceives() public {
        DelegateRegistryMock registry = new DelegateRegistryMock();
        OGClubClubs c = _withRegistry(registry);
        vm.prank(alice);
        pepes.approve(bob, 2);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        c.mintClub(2);
        // Exact v2 rights=0, collection, current holder and token id are required.
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 2, bytes32(uint256(1)), true);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        c.mintClub(2);
        vm.prank(alice);
        registry.delegateERC721(bob, address(furniture), 2, bytes32(0), true);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        c.mintClub(2);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 2, bytes32(0), true);
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        vm.expectCall(
            address(registry),
            abi.encodeCall(registry.checkDelegateForERC721, (bob, alice, address(pepes), 2, bytes32(0)))
        );
        vm.prank(bob);
        assertEq(c.mintClub(2), 2);
        assertEq(c.ownerOf(2), bob);
        assertEq(pepes.ownerOf(2), alice);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(bob), bobBefore - PRICE);
        assertTrue(c.clubsMinted(2));
        vm.prank(operator);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        c.mintClub(1);
    }

    function test_DisabledDelegationAndOwnerDoesNotCallRegistry() public {
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        clubs.mintClub(2);
        vm.prank(alice);
        assertEq(clubs.mintClub(2), 2);
        // An unavailable registry cannot break the direct holder path.
        OGClubClubs c = _withRegistry(IDelegateRegistry(makeAddr("no registry code")));
        vm.prank(alice);
        assertEq(c.mintClub(1), 1);
    }

    function test_DelegationRevocationAndPepeTransferInvalidateOldHolderDelegations() public {
        DelegateRegistryMock registry = new DelegateRegistryMock();
        OGClubClubs c = _withRegistry(registry);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 2, bytes32(0), true);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 2, bytes32(0), false);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        c.mintClub(2);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 2, bytes32(0), true);
        vm.prank(alice);
        pepes.transferFrom(alice, operator, 2);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        c.mintClub(2);
        vm.prank(operator);
        registry.delegateERC721(bob, address(pepes), 2, bytes32(0), true);
        vm.prank(bob);
        c.mintClub(2);
        assertEq(c.ownerOf(2), bob);
    }

    function test_PepeAndClubTransfersNeverResetMintRight() public {
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        clubs.mintClub(1);
        vm.startPrank(alice);
        pepes.transferFrom(alice, bob, 1);
        clubs.transferFrom(alice, operator, 1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        clubs.mintClub(1);
        vm.prank(operator);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        clubs.mintClub(1);
        assertTrue(clubs.clubsMinted(1));
        assertEq(clubs.totalSupply(), 1);
        assertEq(clubs.ownerOf(1), operator);
    }

    function test_NonexistentPepeRevertsAndSparseZeroMaxIdsArePreserved() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        clubs.mintClub(999);
        uint256[3] memory ids = [uint256(0), 9876, type(uint256).max];
        for (uint256 i; i < ids.length; ++i) {
            pepes.mint(alice, ids[i]);
            vm.prank(alice);
            assertEq(clubs.mintClub(ids[i]), ids[i]);
            assertTrue(clubs.clubsMinted(ids[i]));
            assertEq(clubs.ownerOf(ids[i]), alice);
            assertEq(clubs.tokenByIndex(i + 1), ids[i]);
            assertEq(clubs.levelOf(ids[i]), 1);
        }
    }

    function test_ConstructorRejectsZeroPepesAndEachZeroUpgradePrice() public {
        vm.expectRevert(OGClubClubs.ZeroAddress.selector);
        new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            IERC721(address(0)),
            IDelegateRegistry(address(0)),
            OGClubClubs.UpgradePrices(201, 401, 801)
        );
        for (uint256 i; i < 3; ++i) {
            OGClubClubs.UpgradePrices memory prices =
                OGClubClubs.UpgradePrices(i == 0 ? 0 : 201, i == 1 ? 0 : 401, i == 2 ? 0 : 801);
            vm.expectRevert(OGClubClubs.ZeroPrice.selector);
            new OGClubClubs(
                token,
                address(vault),
                PRICE,
                IERC1155(address(furniture)),
                address(this),
                royalty,
                pepes,
                IDelegateRegistry(address(0)),
                prices
            );
        }
    }
}

contract ClubsLevelsTest is ClubsTestBase {
    event ClubUpgraded(uint256 indexed clubId, uint8 newLevel, address indexed payer, uint256 burned, uint256 toVault);
    event MetadataUpdate(uint256 tokenId);

    function test_LevelsSizesExactOddSplitsAndEventsThroughMax() public {
        assertEq(clubs.levelOf(1), 1);
        assertEq(clubs.sizeOf(1), 10);
        assertEq(clubs.upgradePrice(1), 201);
        assertEq(clubs.upgradePrice(2), 401);
        assertEq(clubs.upgradePrice(3), 801);
        clubs.setSaleOpen(false); // Sale control only gates minting.
        for (uint8 level = 1; level < 4; ++level) {
            uint256 cost = clubs.upgradePrice(level);
            uint256 payer = token.balanceOf(alice);
            uint256 burned = token.balanceOf(clubs.BURN_ADDRESS());
            uint256 revenue = token.balanceOf(address(vault));
            vm.expectEmit(true, true, false, true, address(clubs));
            emit ClubUpgraded(1, level + 1, alice, cost / 2, cost - cost / 2);
            vm.expectEmit(false, false, false, true, address(clubs));
            emit MetadataUpdate(1);
            vm.prank(alice);
            clubs.upgradeClub(1);
            assertEq(clubs.levelOf(1), level + 1);
            assertEq(clubs.sizeOf(1), 10 + 2 * uint256(level));
            assertEq(token.balanceOf(alice), payer - cost);
            assertEq(token.balanceOf(clubs.BURN_ADDRESS()), burned + cost / 2);
            assertEq(token.balanceOf(address(vault)), revenue + cost - cost / 2);
            assertEq(token.balanceOf(address(clubs)), 0);
        }
        assertEq(clubs.upgradePrice(4), 0);
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.MaxLevel.selector);
        clubs.upgradeClub(1);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.upgradePrice(0);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.upgradePrice(5);
    }

    function test_OnlyHolderOrApprovedMayUpgradeAndOperatorPays() public {
        fund(operator, 5000);
        vm.prank(operator);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector); // contract owner has no right
        clubs.upgradeClub(1);
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        clubs.approve(operator, 1);
        vm.prank(operator);
        clubs.upgradeClub(1);
        assertEq(token.balanceOf(operator), 4799);
        vm.prank(alice);
        clubs.approve(address(0), 1);
        vm.prank(operator);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1);
        vm.prank(alice);
        clubs.setApprovalForAll(operator, true);
        vm.prank(operator);
        clubs.upgradeClub(1);
        assertEq(token.balanceOf(operator), 4398);
        assertEq(token.balanceOf(alice), aliceBefore);
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        vm.prank(operator);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1);
        vm.prank(bob);
        clubs.upgradeClub(1);
        assertEq(clubs.levelOf(1), 4);
    }

    function test_UpgradeKeepsTilesAndAllowsOnlyNewFrontRowsAndColumns() public {
        place(alice, 1, 1, 9, 9, 0);
        for (uint8 level = 1; level < 4; ++level) {
            uint8 edge = uint8(clubs.sizeOf(1));
            uint256 item = 100 + level;
            clubs.setFootprint(item, 1, 1, false);
            stock(alice, item, 1);
            vm.expectRevert(OGClubClubs.OutOfRoom.selector);
            place(alice, 1, item, edge, 9, 0);
            vm.expectRevert(OGClubClubs.OutOfRoom.selector);
            place(alice, 1, item, 9, edge, 0);
            vm.expectRevert(OGClubClubs.OutOfRoom.selector);
            place(alice, 1, item, edge + 1, edge + 1, 0);
            bytes32 layout = keccak256(abi.encode(clubs.piecesOf(1)));
            vm.prank(alice);
            clubs.upgradeClub(1);
            assertEq(keccak256(abi.encode(clubs.piecesOf(1))), layout);
            assertTrue(clubs.tileTaken(1, 9, 9));
            place(alice, 1, item, edge + 1, edge + 1, 0);
            assertTrue(clubs.tileTaken(1, edge + 1, edge + 1));
        }
        assertTrue(clubs.tileTaken(1, 11, 11));
        assertTrue(clubs.tileTaken(1, 13, 13));
        assertTrue(clubs.tileTaken(1, 15, 15));
        assertFalse(clubs.tileTaken(1, 0, 4));
        assertFalse(clubs.tileTaken(1, 1, 4));
    }

    function test_DoorAndFixedStrideAtEveryLevel() public {
        for (uint8 level = 1; level <= 4; ++level) {
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 1, 0, 4, 0);
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 1, 1, 4, 0);
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 3, 0, 3, 0);
            if (level < 4) {
                vm.prank(alice);
                clubs.upgradeClub(1);
            }
        }
        place(alice, 1, 1, 4, 6, 0); // Old stride's bits 64/65 must not be interpreted as the door.
        assertTrue(clubs.tileTaken(1, 4, 6));
    }

    function test_MissingClubLevelSizeDesignWallViewsAndUpgradeRevert() public {
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.levelOf(9);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.sizeOf(9);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.hasDesign(9, 1);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.wallTaken(9, 0, 0);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.upgradeClub(9);
    }

    function test_ShortUpgradeApprovalRollsBackLevelPaymentAndLayout() public {
        place(alice, 1, 1, 9, 9, 0);
        vm.prank(alice);
        token.approve(address(clubs), 200);
        uint256 payer = token.balanceOf(alice);
        uint256 burned = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 revenue = token.balanceOf(address(vault));
        vm.prank(alice);
        vm.expectRevert();
        clubs.upgradeClub(1);
        assertEq(clubs.levelOf(1), 1);
        assertEq(clubs.pieceCount(1), 1);
        assertTrue(clubs.tileTaken(1, 9, 9));
        assertEq(token.balanceOf(alice), payer);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), burned);
        assertEq(token.balanceOf(address(vault)), revenue);
        assertEq(token.allowance(alice, address(clubs)), 200);
    }

    function test_UpgradeChecksBothFinalReceiptsAndRollsBackLevel() public {
        ClubReceiptToken adversary = new ClubReceiptToken();
        OGClubClubs c = new OGClubClubs(
            adversary,
            address(vault),
            101,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            IDelegateRegistry(address(0)),
            OGClubClubs.UpgradePrices(201, 401, 801)
        );
        c.setSaleOpen(true);
        adversary.mint(alice, 10000);
        adversary.mint(address(vault), 1000);
        vm.startPrank(alice);
        adversary.approve(address(c), 10000);
        c.mintClub(1);
        vm.stopPrank();
        for (uint8 mode; mode < 4; ++mode) {
            adversary.configure(address(vault), mode);
            vm.prank(alice);
            vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
            c.upgradeClub(1);
            assertEq(c.levelOf(1), 1);
            assertEq(adversary.balanceOf(alice), 9899);
            assertEq(adversary.balanceOf(address(vault)), 1051);
            assertEq(adversary.balanceOf(c.BURN_ADDRESS()), 50);
            assertEq(adversary.allowance(alice, address(c)), 9899);
            assertEq(adversary.balanceOf(address(c)), 0);
        }
    }

    function test_TaxedFalseAndCallbackTokensOnUpgrade() public {
        TestToken adversary = new TestToken(18);
        OGClubClubs c = new OGClubClubs(
            adversary,
            address(vault),
            101,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            IDelegateRegistry(address(0)),
            OGClubClubs.UpgradePrices(10001, 20001, 40001)
        );
        c.setSaleOpen(true);
        adversary.mint(alice, 1000000);
        vm.startPrank(alice);
        adversary.approve(address(c), 1000000);
        c.mintClub(1);
        vm.stopPrank();
        for (uint256 senderFee; senderFee < 2; ++senderFee) {
            adversary.configureFee(100, senderFee != 0);
            vm.prank(alice);
            vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
            c.upgradeClub(1);
            assertEq(c.levelOf(1), 1);
            assertEq(adversary.balanceOf(alice), 999899);
        }
        adversary.configureFee(0, false);
        adversary.configureFalse(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(adversary)));
        c.upgradeClub(1);
        adversary.configureFalse(false);
        adversary.configureCallback(address(c), abi.encodeCall(c.upgradeClub, (1)));
        vm.prank(alice);
        c.upgradeClub(1);
        assertFalse(adversary.callbackSucceeded());
        assertEq(c.levelOf(1), 2);
        adversary.configureCallback(address(c), abi.encodeCall(c.mintClub, (2)));
        vm.prank(alice);
        c.upgradeClub(1);
        assertFalse(adversary.callbackSucceeded());
        assertEq(c.levelOf(1), 3);
    }
}

contract ClubsWallsTest is ClubsTestBase {
    event FurniturePlaced(
        uint256 indexed clubId, uint256 indexed furnitureId, uint8 x, uint8 y, uint8 rot, uint256 index, bool wall
    );
    event MetadataUpdate(uint256 tokenId);

    function _wall(uint256 id, uint8 width) private {
        clubs.setFootprint(id, width, 1, true);
        stock(alice, id, 3);
    }

    function test_BothWallsAllWidthsAndEvents() public {
        vm.startPrank(alice);
        clubs.upgradeClub(1);
        clubs.upgradeClub(1);
        clubs.upgradeClub(1);
        vm.stopPrank();
        for (uint8 side; side < 2; ++side) {
            uint8 pos = side == 0 ? 0 : 5;
            for (uint8 width = 1; width <= 4; ++width) {
                uint256 id = 100 + uint256(side) * 4 + width;
                _wall(id, width);
                vm.expectEmit(true, true, false, true, address(clubs));
                emit FurniturePlaced(1, id, pos, 0, side, uint256(side) * 4 + width - 1, true);
                vm.expectEmit(false, false, false, true, address(clubs));
                emit MetadataUpdate(1);
                place(alice, 1, id, pos, 0, side);
                for (uint8 i; i < width; ++i) {
                    assertTrue(clubs.wallTaken(1, side, pos + i));
                }
                assertTrue(clubs.piecesOf(1)[uint256(side) * 4 + width - 1].wall);
                pos += width;
            }
        }
        assertEq(clubs.pieceCount(1), 8);
    }

    function test_WallDoorIntervalsAndOtherSideIndependent() public {
        _wall(10, 2);
        _wall(11, 2);
        _wall(12, 2);
        vm.expectRevert(OGClubClubs.BlocksDoor.selector);
        place(alice, 1, 10, 3, 0, 1);
        vm.expectRevert(OGClubClubs.BlocksDoor.selector);
        place(alice, 1, 10, 4, 0, 1);
        place(alice, 1, 10, 5, 0, 1);
        place(alice, 1, 11, 3, 0, 0);
        place(alice, 1, 12, 2, 0, 1);
        assertFalse(clubs.wallTaken(1, 1, 4));
        assertTrue(clubs.wallTaken(1, 0, 4));
    }

    function test_EndOfWallAtEverySizeAndPreservedAfterUpgrade() public {
        _wall(50, 2);
        for (uint8 level = 1; level <= 4; ++level) {
            uint8 size = uint8(clubs.sizeOf(1));
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 50, 3, 0, 1);
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 50, 4, 0, 1);
            for (uint8 side; side < 2; ++side) {
                uint256 id = 100 + uint256(level) * 2 + side;
                _wall(id, 2);
                vm.expectRevert(OGClubClubs.OutOfRoom.selector);
                place(alice, 1, id, size - 1, 0, side);
                vm.expectRevert(OGClubClubs.OutOfRoom.selector);
                place(alice, 1, id, size, 0, side);
                place(alice, 1, id, size - 2, 0, side);
            }
            if (level < 4) {
                vm.prank(alice);
                clubs.upgradeClub(1);
            }
        }
        for (uint8 pos = 8; pos < 16; ++pos) {
            for (uint8 side; side < 2; ++side) {
                assertTrue(clubs.wallTaken(1, side, pos));
            }
        }
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.wallTaken(1, 0, 16);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.wallTaken(1, 2, 0);
    }

    function test_WallOverlapYSideAndIndependentFloorBitmap() public {
        _wall(10, 2);
        _wall(11, 1);
        _wall(12, 1);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 0, 1, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 0, 0, 2);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 0, 0, 255);
        place(alice, 1, 10, 0, 0, 0);
        vm.expectRevert(OGClubClubs.TileTaken.selector);
        place(alice, 1, 11, 1, 0, 0);
        place(alice, 1, 11, 0, 0, 1);
        vm.expectRevert(OGClubClubs.TileTaken.selector);
        place(alice, 1, 12, 0, 0, 1);
        place(alice, 1, 1, 0, 0, 0);
        assertTrue(clubs.tileTaken(1, 0, 0));
        assertFalse(clubs.tileTaken(1, 1, 0));
        assertTrue(clubs.wallTaken(1, 0, 0));
        assertTrue(clubs.wallTaken(1, 1, 0));
        assertEq(clubs.pieceCount(1), 3);
    }

    function test_WallFlagAndDimensionsLockTogetherAcrossAllClubs() public {
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(10, 1, 2, true);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(10, 0, 1, true);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(10, 5, 1, true);
        clubs.setFootprint(10, 2, 2, false);
        _wall(10, 3);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 9, 0, 0);
        clubs.setFootprint(10, 2, 1, true);
        place(alice, 1, 10, 0, 0, 0);
        (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(10);
        assertEq(w, 2);
        assertEq(h, 1);
        assertTrue(set && locked && wall);
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        clubs.setFootprint(10, 2, 1, false);
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        clubs.setFootprint(10, 1, 1, true);
        vm.prank(bob);
        clubs.mintClub(3);
        stock(bob, 10, 1);
        place(bob, 3, 10, 5, 0, 1);
        assertTrue(clubs.wallTaken(3, 1, 6));
    }

    function test_OneOfEachFloorAndWallPerClubSurvivesClubTransfer() public {
        _wall(10, 1);
        place(alice, 1, 1, 2, 2, 0);
        place(alice, 1, 10, 0, 0, 0);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, 1, 3, 3, 1);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, 10, 5, 0, 1);
        vm.prank(alice);
        clubs.mintClub(2);
        place(alice, 2, 1, 2, 2, 0);
        place(alice, 2, 10, 0, 0, 0);
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        stock(bob, 10, 1);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(bob, 1, 1, 3, 3, 0);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(bob, 1, 10, 5, 0, 1);
        assertTrue(clubs.hasDesign(1, 1));
        assertTrue(clubs.hasDesign(1, 10));
        assertTrue(clubs.hasDesign(2, 1));
        assertEq(clubs.pieceCount(1), 2);
        assertEq(clubs.pieceCount(2), 2);
        assertEq(furniture.balanceOf(address(clubs), 10), 2);
    }
}
