// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Sepolia-only Swarm Pepe stand-in. Anyone can mint an unused id to themselves.
contract MockSwarmPepe is ERC721 {
    constructor() ERC721("Mock Swarm Pepe", "mPEPE") {}

    function mint(uint256 pepeId) external {
        _safeMint(msg.sender, pepeId);
    }
}
