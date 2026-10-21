// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockOG} from "../src/mocks/MockOG.sol";

/// @dev Off-chain deployment scripts, never application contracts.
abstract contract ClubDeployment is Script {
    error WrongChain();
    error InvalidFootprintJSON();
    error DuplicateFootprint(uint256 id);

    /// @notice A JSON array of [id,w,h,wall] (wall is 0 or 1) rows. [] leaves all footprints owner-configurable.
    /// @dev Pass file contents via FOOTPRINTS_JSON; this needs no Foundry filesystem permission change.
    function parseFootprints(string memory json) public pure returns (uint256[][] memory rows) {
        rows = abi.decode(vm.parseJson(json), (uint256[][]));
        for (uint256 i; i < rows.length; ++i) {
            // Typed parsing rejects negative IDs instead of decoding their two's-complement
            // representation as a different uint256 furniture ID.
            rows[i] = vm.parseJsonUintArray(json, string.concat("$[", vm.toString(i), "]"));
            if (rows[i].length != 4) revert InvalidFootprintJSON();
            if (
                rows[i][1] == 0 || rows[i][1] > 4 || rows[i][2] == 0 || rows[i][2] > 4 || rows[i][3] > 1
                    || (rows[i][3] == 1 && rows[i][2] != 1)
            ) {
                revert InvalidFootprintJSON();
            }
            for (uint256 j; j < i; ++j) {
                if (rows[i][0] == rows[j][0]) revert DuplicateFootprint(rows[i][0]);
            }
        }
    }

    function _configure(OGClubClubs clubs, uint256[][] memory rows, bool open) internal {
        for (uint256 i; i < rows.length; ++i) {
            // Bounds are validated before deployment, so these casts cannot truncate.
            clubs.setFootprint(rows[i][0], uint8(rows[i][1]), uint8(rows[i][2]), rows[i][3] == 1);
        }
        if (open) clubs.setSaleOpen(true);
    }

    function _printClubs(OGClubClubs clubs, address owner, address royaltyReceiver) internal view {
        console2.log("OGClubClubs", address(clubs));
        console2.log(
            "OGClubClubs constructor args (token, vault, price, furniture, owner, royaltyReceiver, pepes, delegates, upgradePrices):"
        );
        console2.logBytes(
            abi.encode(
                clubs.token(),
                clubs.vault(),
                clubs.price(),
                clubs.furniture(),
                owner,
                royaltyReceiver,
                clubs.pepes(),
                clubs.delegates(),
                OGClubClubs.UpgradePrices(clubs.upgradePrice(1), clubs.upgradePrice(2), clubs.upgradePrice(3))
            )
        );
        console2.log("token", address(clubs.token()));
        console2.log("vault", clubs.vault());
        console2.log("price (token base units)", clubs.price());
        console2.log("furniture", address(clubs.furniture()));
        console2.log("Swarm Pepes", address(clubs.pepes()));
        console2.log("delegate.xyz v2 registry", address(clubs.delegates()));
        console2.log("level 2 price", clubs.upgradePrice(1));
        console2.log("level 3 price", clubs.upgradePrice(2));
        console2.log("level 4 price", clubs.upgradePrice(3));
        console2.log("owner", owner);
        console2.log("royaltyReceiver", royaltyReceiver);
        console2.log("saleOpen", clubs.saleOpen());
    }
}

/// @notice Deploy the testnet club stack and open its sale after loading footprints.
/// @dev OWNER is the broadcaster for the owner-only configuration calls. No temporary owner is used.
contract DeployClubsSepolia is ClubDeployment {
    uint256 public constant CLUB_PRICE = 100_000e18;
    address public constant DELEGATE_REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;

    function run()
        external
        returns (MockOG token, OGClubFurniture furniture, OGClubFarmVault vault, OGClubClubs clubs, MockSwarmPepe pepes)
    {
        address owner = vm.envAddress("OWNER");
        return deploy(owner, vm.envOr("ROYALTY_RECEIVER", owner), vm.envOr("FOOTPRINTS_JSON", string("[]")));
    }

    function deploy(address owner, address royaltyReceiver, string memory footprintJSON)
        public
        returns (MockOG token, OGClubFurniture furniture, OGClubFarmVault vault, OGClubClubs clubs, MockSwarmPepe pepes)
    {
        if (block.chainid != 11155111 && block.chainid != 31337) revert WrongChain();
        uint256[][] memory rows = parseFootprints(footprintJSON);
        vm.startBroadcast(owner);
        token = new MockOG(owner);
        furniture = new OGClubFurniture(owner, royaltyReceiver);
        vault = new OGClubFarmVault(token, owner);
        pepes = new MockSwarmPepe();
        clubs = new OGClubClubs(
            token,
            address(vault),
            CLUB_PRICE,
            IERC1155(address(furniture)),
            owner,
            royaltyReceiver,
            pepes,
            IDelegateRegistry(DELEGATE_REGISTRY),
            OGClubClubs.UpgradePrices(200_000e18, 400_000e18, 800_000e18)
        );
        _configure(clubs, rows, true);
        vm.stopBroadcast();
        console2.log("MockOG (unrestricted testnet mint)", address(token));
        console2.log("MockOG constructor args (initialRecipient):");
        console2.logBytes(abi.encode(owner));
        console2.log("OGClubFurniture", address(furniture));
        console2.log("OGClubFurniture constructor args (owner, royaltyReceiver):");
        console2.logBytes(abi.encode(owner, royaltyReceiver));
        console2.log("OGClubFarmVault", address(vault));
        console2.log("OGClubFarmVault constructor args (token, owner):");
        console2.logBytes(abi.encode(token, owner));
        console2.log("MockSwarmPepe (Sepolia-only public mint)", address(pepes));
        console2.log("MockSwarmPepe constructor args: none");
        _printClubs(clubs, owner, royaltyReceiver);
    }
}

/// @notice Deploy from an EOA key, with OWNER (including a Safe) receiving all administration rights.
/// @dev Footprints and sale opening are printed owner calls, never transactions from a Safe's address.
contract DeployClubsMainnet is ClubDeployment {
    error VaultTokenMismatch();
    error InvalidUpgradePrices();

    struct Config {
        IERC20 token;
        address vault;
        uint256 price;
        IERC1155 furniture;
        address owner;
        address royaltyReceiver;
        IERC721 pepes;
        IDelegateRegistry delegates;
        OGClubClubs.UpgradePrices upgradePrices;
    }

    function run() external returns (OGClubClubs clubs) {
        uint256[] memory prices = vm.envUint("UPGRADE_PRICES", ",");
        if (prices.length != 3) revert InvalidUpgradePrices();
        Config memory config = Config({
            token: IERC20(vm.envAddress("OG_TOKEN")),
            vault: vm.envAddress("FARM_VAULT"),
            price: vm.envUint("CLUB_PRICE"),
            furniture: IERC1155(vm.envAddress("FURNITURE")),
            owner: vm.envAddress("OWNER"),
            royaltyReceiver: vm.envAddress("ROYALTY_RECEIVER"),
            pepes: IERC721(vm.envAddress("SWARM_PEPES")),
            delegates: IDelegateRegistry(vm.envAddress("DELEGATE_REGISTRY")),
            upgradePrices: OGClubClubs.UpgradePrices(prices[0], prices[1], prices[2])
        });
        return deploy(vm.envUint("DEPLOYER_KEY"), config, vm.envOr("FOOTPRINTS_JSON", string("[]")));
    }

    function deploy(uint256 deployerKey, Config memory config, string memory footprintJSON)
        public
        returns (OGClubClubs clubs)
    {
        if (block.chainid != 1 && block.chainid != 31337) revert WrongChain();
        uint256[][] memory rows = parseFootprints(footprintJSON);
        // Live dependency validation belongs in the script, never in a factory constructor.
        if (address(OGClubFarmVault(config.vault).token()) != address(config.token)) revert VaultTokenMismatch();
        vm.startBroadcast(deployerKey);
        clubs = new OGClubClubs(
            config.token,
            config.vault,
            config.price,
            config.furniture,
            config.owner,
            config.royaltyReceiver,
            config.pepes,
            config.delegates,
            config.upgradePrices
        );
        vm.stopBroadcast();
        _printClubs(clubs, config.owner, config.royaltyReceiver);
        for (uint256 i; i < rows.length; ++i) {
            console2.log("OWNER must call OGClubClubs with footprint calldata:");
            console2.logBytes(
                abi.encodeCall(clubs.setFootprint, (rows[i][0], uint8(rows[i][1]), uint8(rows[i][2]), rows[i][3] == 1))
            );
        }
        console2.log("After configuring footprints/metadata, OWNER opens sale with calldata:");
        console2.logBytes(abi.encodeCall(clubs.setSaleOpen, (true)));
    }
}
