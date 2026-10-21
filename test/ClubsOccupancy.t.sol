// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {ClubsOccupancy} from "./helpers/ClubsOccupancy.sol";

/// @dev Tests of the invariant reader itself. Artificial storage writes here validate its
/// decoding; the actual behavior campaigns only place real furniture through ERC1155 transfers.
contract ClubsOccupancyTest is ClubsTestBase {
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_WholeWordsMatchEveryPublicCell(uint256 floor, uint64 walls, uint8 levelSeed) public {
        ClubsOccupancy.Slots memory slots = ClubsOccupancy.locate(stdstore, clubs, 1);
        assertEq(clubs.levelOf(1), 1);
        assertEq(clubs.ownerOf(1), alice);
        assertEq(clubs.pieceCount(1), 0);
        (uint256 emptyFloor, uint256 emptyWalls) = ClubsOccupancy.read(clubs, slots);
        assertEq(emptyFloor, 0);
        assertEq(emptyWalls, 0);
        uint8 level = 1 + levelSeed % 4;
        vm.startPrank(alice);
        for (uint8 l = 1; l < level; ++l) {
            clubs.upgradeClub(1);
        }
        vm.stopPrank();

        vm.store(address(clubs), slots.floor, bytes32(floor));
        vm.store(address(clubs), slots.walls, bytes32(uint256(walls)));
        (uint256 observedFloor, uint256 observedWalls) = ClubsOccupancy.read(clubs, slots);
        assertEq(observedFloor, floor);
        assertEq(observedWalls, walls);
        uint8 size = 8 + 2 * level;
        for (uint8 y; y < size; ++y) {
            for (uint8 x; x < size; ++x) {
                assertEq(clubs.tileTaken(1, x, y), observedFloor & (uint256(1) << (uint256(y) * 16 + x)) != 0);
            }
            for (uint8 side; side < 2; ++side) {
                assertEq(clubs.wallTaken(1, side, y), observedWalls & (uint256(1) << (uint256(side) * 32 + y)) != 0);
            }
        }
    }

    function test_ReaderIncludesHiddenCellsAndUnusedWallBits() public {
        ClubsOccupancy.Slots memory slots = ClubsOccupancy.locate(stdstore, clubs, 1);
        // A room at level 1 cannot query (15,15); the per-action storage check must still catch it.
        vm.store(address(clubs), slots.floor, bytes32(uint256(1) << 255));
        vm.store(address(clubs), slots.walls, bytes32(uint256(1) << 255));
        (uint256 floor, uint256 walls) = ClubsOccupancy.read(clubs, slots);
        assertEq(floor, uint256(1) << 255);
        assertEq(walls, uint256(1) << 255);
        assertFalse(clubs.tileTaken(1, 0, 0));
        assertFalse(clubs.wallTaken(1, 0, 0));
        assertFalse(clubs.wallTaken(1, 1, 0));
    }

    function test_SparseClubIdsDiscoverIndependentSlotsAndPreserveExistingOccupancy() public {
        place(alice, 1, 1, 2, 2, 0);
        uint256[2] memory ids = [uint256(0), type(uint256).max];
        for (uint256 i; i < ids.length; ++i) {
            pepes.mint(alice, ids[i]);
            vm.prank(alice);
            clubs.mintClub(ids[i]);
            ClubsOccupancy.Slots memory slots = ClubsOccupancy.locate(stdstore, clubs, ids[i]);
            vm.store(address(clubs), slots.floor, bytes32(uint256(1) << (i + 1)));
            assertTrue(clubs.tileTaken(ids[i], uint8(i + 1), 0));
        }
        assertTrue(clubs.tileTaken(1, 2, 2));
        assertEq(clubs.pieceCount(1), 1);
        assertTrue(clubs.tileTaken(0, 1, 0));
        assertFalse(clubs.tileTaken(0, 2, 0));
        assertTrue(clubs.tileTaken(type(uint256).max, 2, 0));
        assertFalse(clubs.tileTaken(type(uint256).max, 1, 0));
    }
}
