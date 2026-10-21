// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The delegate.xyz v2 read interface used for Swarm Pepe mint authorization.
interface IDelegateRegistry {
    function checkDelegateForERC721(address to, address from, address contract_, uint256 tokenId, bytes32 rights)
        external
        view
        returns (bool);
}
