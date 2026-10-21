// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {OGClubClubs} from "../../src/OGClubClubs.sol";

/// @dev Read whole occupancy words during invariant campaigns instead of making hundreds of
/// repeated external calls per club per action. Slots are discovered from the public getters,
/// never hardcoded. The campaigns also check every public getter at the end of each sequence.
library ClubsOccupancy {
    using stdStorage for StdStorage;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Slots {
        bytes32 floor;
        bytes32 walls;
    }

    /// @dev Call immediately after minting. stdStorage's temporary probes restore the original
    /// values. Discovery on empty words avoids confusing a bit getter with a whole-word getter.
    function locate(StdStorage storage store, OGClubClubs clubs, uint256 id) internal returns (Slots memory slots) {
        require(clubs.pieceCount(id) == 0, "discover occupancy before placing furniture");
        slots.floor = bytes32(
            store.target(address(clubs))
                .sig(clubs.tileTaken.selector)
                .with_key(id)
                .with_key(uint256(0))
                .with_key(uint256(0))
                .find()
        );
        slots.walls = bytes32(
            store.target(address(clubs))
                .sig(clubs.wallTaken.selector)
                .with_key(id)
                .with_key(uint256(0))
                .with_key(uint256(0))
                .find()
        );
        bytes32 otherWall = bytes32(
            store.target(address(clubs))
                .sig(clubs.wallTaken.selector)
                .with_key(id)
                .with_key(uint256(1))
                .with_key(uint256(0))
                .find()
        );
        require(slots.floor != slots.walls, "floor and wall storage must be independent");
        require(slots.walls == otherWall, "uint32[2] walls must share one word");
        (uint256 floor, uint256 walls) = read(clubs, slots);
        require(floor == 0 && walls == 0, "slot discovery must preserve empty occupancy");
    }

    function read(OGClubClubs clubs, Slots memory slots) internal view returns (uint256 floor, uint256 walls) {
        require(slots.floor != slots.walls, "occupancy slots not registered");
        return (uint256(vm.load(address(clubs), slots.floor)), uint256(vm.load(address(clubs), slots.walls)));
    }
}
