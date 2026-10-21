// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IDelegateRegistry} from "../../src/interfaces/IDelegateRegistry.sol";

contract PepeMock is ERC721 {
    constructor() ERC721("Test Pepes", "PEPE") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract DelegateRegistryMock is IDelegateRegistry {
    mapping(bytes32 => bool) private _delegations;

    function delegateERC721(address to, address collection, uint256 id, bytes32 rights, bool enable) external {
        _delegations[keccak256(abi.encode(to, msg.sender, collection, id, rights))] = enable;
    }

    function checkDelegateForERC721(address to, address from, address collection, uint256 id, bytes32 rights)
        external
        view
        returns (bool)
    {
        return _delegations[keccak256(abi.encode(to, from, collection, id, rights))];
    }
}
