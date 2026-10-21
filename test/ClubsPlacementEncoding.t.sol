// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";

contract ClubsPlacementEncodingTest is ClubsTestBase {
    uint256 internal constant ITEM = type(uint256).max;

    function setUp() public override {
        super.setUp();
        // An existing floor and wall make rollback assertions sensitive to damage to either bitmap.
        place(alice, 1, 1, 9, 9, 0);
        clubs.setFootprint(50, 1, 1, true);
        stock(alice, 50, 1);
        place(alice, 1, 50, 8, 0, 0);
        stock(alice, ITEM, 2);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_HighBitsInEveryUint8WordAreRejectedWithoutTruncation(uint256 high, uint8 fieldSeed, bool wall)
        public
    {
        clubs.setFootprint(ITEM, 2, 1, wall);
        uint256[3] memory coordinates = [uint256(5), wall ? 0 : 5, 1];
        uint256 field = bound(fieldSeed, 0, 2);
        // Preserve a valid low byte. An unchecked uint8 cast would accept this same placement.
        coordinates[field] |= bound(high, 1, type(uint248).max) << 8;
        bytes memory malformed = abi.encode(uint256(1), coordinates[0], coordinates[1], coordinates[2]);
        _rejectThenRetry(malformed, wall);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_EveryNoncanonicalLengthFailsBeforeChangingAnyPlacementState(uint16 lengthSeed, bytes32 garbage)
        public
    {
        clubs.setFootprint(ITEM, 2, 1, false);
        uint256 length = bound(lengthSeed, 0, 511);
        if (length >= 128) ++length; // Exactly 128 bytes is the only permitted length.
        bytes memory canonical = abi.encode(uint256(1), uint256(5), uint256(5), uint256(1));
        bytes memory malformed = new bytes(length);
        for (uint256 i; i < length; ++i) {
            malformed[i] = i < 128 ? canonical[i] : garbage[i % 32];
        }
        _rejectThenRetry(malformed, false);
    }

    function test_ZeroAndMaximumDesignIdsRemainDistinctAcrossFloorAndWalls() public {
        clubs.setFootprint(0, 1, 1, false);
        clubs.setFootprint(ITEM, 1, 1, true);
        stock(alice, 0, 2);
        place(alice, 1, 0, 0, 0, 0);
        place(alice, 1, ITEM, 0, 0, 1);
        assertTrue(clubs.hasDesign(1, 0));
        assertTrue(clubs.hasDesign(1, ITEM));
        assertTrue(clubs.tileTaken(1, 0, 0));
        assertTrue(clubs.wallTaken(1, 1, 0));
        bytes32 beforeState = _snapshot();
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, 0, 2, 2, 0);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, ITEM, 5, 0, 0);
        assertEq(_snapshot(), beforeState);
        assertEq(furniture.balanceOf(alice, 0), 1);
        assertEq(furniture.balanceOf(address(clubs), 0), 1);
    }

    function _rejectThenRetry(bytes memory malformed, bool wall) private {
        bytes32 beforeState = _snapshot();
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.BadPlacementData.selector);
        furniture.safeTransferFrom(alice, address(clubs), ITEM, 1, malformed);
        assertEq(_snapshot(), beforeState, "rejected bytes modified placement state or custody");
        assertFalse(clubs.hasDesign(1, ITEM));
        (,,, bool locked,) = clubs.footprintOf(ITEM);
        assertFalse(locked);

        // Positive control: the canonical encoding of the low bytes must still work with this same design.
        place(alice, 1, ITEM, 5, wall ? 0 : 5, 1);
        assertEq(clubs.pieceCount(1), 3);
        assertTrue(clubs.hasDesign(1, ITEM));
        assertEq(furniture.balanceOf(alice, ITEM), 1);
        assertEq(furniture.balanceOf(address(clubs), ITEM), 1);
        assertTrue(clubs.tileTaken(1, 9, 9));
        assertTrue(clubs.wallTaken(1, 0, 8));
        assertFalse(clubs.tileTaken(1, 0, 4));
        assertFalse(clubs.tileTaken(1, 1, 4));
        assertFalse(clubs.wallTaken(1, 1, 4));
        if (wall) {
            assertTrue(clubs.wallTaken(1, 1, 5));
            assertTrue(clubs.wallTaken(1, 1, 6));
            assertFalse(clubs.tileTaken(1, 5, 5));
        } else {
            assertTrue(clubs.tileTaken(1, 5, 5));
            assertTrue(clubs.tileTaken(1, 5, 6));
            assertFalse(clubs.tileTaken(1, 6, 5));
            assertFalse(clubs.wallTaken(1, 1, 5));
        }
        (,,, locked,) = clubs.footprintOf(ITEM);
        assertTrue(locked);
    }

    function _snapshot() private view returns (bytes32 state) {
        (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(ITEM);
        state = keccak256(
            abi.encode(
                clubs.piecesOf(1),
                clubs.pieceCount(1),
                clubs.hasDesign(1, ITEM),
                w,
                h,
                set,
                locked,
                wall,
                furniture.balanceOf(alice, ITEM),
                furniture.balanceOf(address(clubs), ITEM)
            )
        );
        bool[100] memory floor;
        bool[20] memory walls;
        for (uint8 y; y < 10; ++y) {
            for (uint8 x; x < 10; ++x) {
                floor[uint256(y) * 10 + x] = clubs.tileTaken(1, x, y);
            }
            walls[y] = clubs.wallTaken(1, 0, y);
            walls[10 + y] = clubs.wallTaken(1, 1, y);
        }
        return keccak256(abi.encode(state, floor, walls));
    }
}
