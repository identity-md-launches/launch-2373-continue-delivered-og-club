// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @notice Transferable clubs with permanent, on-chain furniture layouts.
/// @dev Furniture custody never leaves this contract. Ownership grants no club transfer or burn privilege.
contract OGClubClubs is ERC721Enumerable, ERC2981, IERC4906, ERC1155Holder, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint96 public constant MAX_ROYALTY_BPS = 1000;
    uint256 public constant MAX_ROOM_SIZE = 16;
    uint256 public constant MAX_PIECES = 285;
    // Bit y * 16 + x: the door (0,4) and its approach (1,4).
    uint256 private constant DOOR_MASK = (uint256(1) << 64) | (uint256(1) << 65);

    IERC20 public immutable token;
    address public immutable vault;
    uint256 public immutable price;
    IERC1155 public immutable furniture;
    IERC721 public immutable pepes;
    IDelegateRegistry public immutable delegates;
    uint256 private immutable _level2Price;
    uint256 private immutable _level3Price;
    uint256 private immutable _level4Price;

    /// @dev Static tuple equivalent to the three level prices; supported by the launch factory.
    struct UpgradePrices {
        uint256 level2;
        uint256 level3;
        uint256 level4;
    }

    bool public saleOpen;
    bool public metadataFrozen;
    string public baseURI;
    mapping(uint256 pepeId => bool) public clubsMinted;
    mapping(uint256 clubId => uint8) private _levels;
    mapping(uint256 clubId => mapping(uint256 furnitureId => bool)) private _designs;
    mapping(uint256 clubId => uint32[2]) private _walls;

    struct Piece {
        uint256 furnitureId;
        uint8 x;
        uint8 y;
        uint8 rot;
        bool wall;
    }

    struct Footprint {
        uint8 w;
        uint8 h;
        bool set;
        bool locked;
        bool wall;
    }

    mapping(uint256 clubId => Piece[]) private _pieces;
    mapping(uint256 clubId => uint256 bitmap) private _tiles;
    mapping(uint256 furnitureId => Footprint) private _footprints;

    error NotPepeHolder();
    error AlreadyMinted();
    error MaxLevel();
    error BadLevel();
    error AlreadyHasDesign();
    error BadPlacementData();
    error SaleClosed();
    error ZeroAddress();
    error ZeroPrice();
    error UnexpectedTokenDebit();
    error MetadataFrozen();
    error RoyaltyTooHigh();
    error NonexistentToken();
    error NotFurniture();
    error NotClubOwner();
    error BadAmount();
    error NoFootprint();
    error FootprintLocked();
    error BadFootprint();
    error OutOfRoom();
    error BlocksDoor();
    error TileTaken();
    error ClubFull();
    error BatchNotAccepted();

    event ClubMinted(
        uint256 indexed id, address indexed to, address indexed payer, uint256 pepeId, uint256 burned, uint256 toVault
    );
    event ClubUpgraded(uint256 indexed clubId, uint8 newLevel, address indexed payer, uint256 burned, uint256 toVault);
    event FurniturePlaced(
        uint256 indexed clubId, uint256 indexed furnitureId, uint8 x, uint8 y, uint8 rot, uint256 index, bool wall
    );
    event SaleOpenSet(bool open);
    event FootprintSet(uint256 indexed furnitureId, uint8 w, uint8 h, bool wall);
    event BaseURISet(string baseURI);
    event MetadataPermanentlyFrozen(string baseURI);
    event RoyaltySet(address indexed receiver, uint96 bps);

    /// @dev No dependency calls: suitable for constructor-only factory deployment on an empty chain.
    constructor(
        IERC20 token_,
        address vault_,
        uint256 price_,
        IERC1155 furniture_,
        address initialOwner,
        address royaltyReceiver,
        IERC721 pepes_,
        IDelegateRegistry delegates_,
        UpgradePrices memory upgradePrices
    ) ERC721("OG Club Clubs", "OGCLUBS") Ownable(_nonzero(initialOwner)) {
        _nonzero(address(token_));
        _nonzero(vault_);
        _nonzero(address(furniture_));
        _nonzero(royaltyReceiver);
        _nonzero(address(pepes_));
        if (upgradePrices.level2 == 0 || upgradePrices.level3 == 0 || upgradePrices.level4 == 0) revert ZeroPrice();
        if (price_ == 0) revert ZeroPrice();
        // A predicted self-address cannot be a revenue destination: no payments may be held here.
        if (
            vault_ == address(this) || vault_ == BURN_ADDRESS || vault_ == address(token_)
                || vault_ == address(furniture_)
        ) {
            revert UnexpectedTokenDebit();
        }
        token = token_;
        vault = vault_;
        price = price_;
        furniture = furniture_;
        pepes = pepes_;
        delegates = delegates_;
        _level2Price = upgradePrices.level2;
        _level3Price = upgradePrices.level3;
        _level4Price = upgradePrices.level4;
        _setDefaultRoyalty(royaltyReceiver, 500);
        emit RoyaltySet(royaltyReceiver, 500);
    }

    /// @notice One club per Pepe, forever. The holder or its delegate pays and receives that id.
    function mintClub(uint256 pepeId) external nonReentrant returns (uint256 id) {
        if (!saleOpen) revert SaleClosed();
        if (clubsMinted[pepeId]) revert AlreadyMinted();
        address holder = pepes.ownerOf(pepeId);
        if (
            msg.sender != holder
                && (address(delegates) == address(0)
                    || !delegates.checkDelegateForERC721(msg.sender, holder, address(pepes), pepeId, bytes32(0)))
        ) revert NotPepeHolder();
        clubsMinted[pepeId] = true;
        _levels[pepeId] = 1;
        (uint256 burned, uint256 toVault) = _pay(price);
        _safeMint(msg.sender, pepeId);
        emit ClubMinted(pepeId, msg.sender, msg.sender, pepeId, burned, toVault);
        return pepeId;
    }

    /// @notice The holder or an approved operator pays to grow the room toward the front.
    function upgradeClub(uint256 clubId) external nonReentrant {
        if (!_isAuthorized(_clubOwner(clubId), msg.sender, clubId)) revert NotClubOwner();
        uint8 level = _levels[clubId];
        if (level == 4) revert MaxLevel();
        _levels[clubId] = level + 1;
        (uint256 burned, uint256 toVault) = _pay(upgradePrice(level));
        emit ClubUpgraded(clubId, level + 1, msg.sender, burned, toVault);
        emit MetadataUpdate(clubId);
    }

    function _pay(uint256 amount) private returns (uint256 burned, uint256 toVault) {
        burned = amount / 2;
        toVault = amount - burned;
        uint256 payerBefore = token.balanceOf(msg.sender);
        uint256 burnBefore = token.balanceOf(BURN_ADDRESS);
        uint256 vaultBefore = token.balanceOf(vault);
        token.safeTransferFrom(msg.sender, BURN_ADDRESS, burned);
        token.safeTransferFrom(msg.sender, vault, toVault);
        // Check the complete payment, including changes the second transfer might make to the first recipient.
        _checkReceipt(BURN_ADDRESS, burnBefore, burned);
        _checkReceipt(vault, vaultBefore, toVault);
        uint256 payerAfter = token.balanceOf(msg.sender);
        if (payerAfter > payerBefore || payerBefore - payerAfter != amount) revert UnexpectedTokenDebit();
    }

    function _checkReceipt(address recipient, uint256 beforeBalance, uint256 amount) private view {
        uint256 afterBalance = token.balanceOf(recipient);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnexpectedTokenDebit();
    }

    /// @notice Permanently place one piece, using abi.encode(clubId, uint8(x), uint8(y), uint8(rot)).
    /// @dev Authorization is for `from`, as required by the placement protocol. A furniture-approved
    ///      operator can therefore place its owner's furniture in a club that owner controls.
    function onERC1155Received(address, address from, uint256 id, uint256 amount, bytes memory data)
        public
        override
        returns (bytes4)
    {
        if (msg.sender != address(furniture)) revert NotFurniture();
        if (amount != 1) revert BadAmount();
        (uint256 clubId, uint8 x, uint8 y, uint8 rot) = _decodePlacement(data);
        if (!_isAuthorized(_clubOwner(clubId), from, clubId)) revert NotClubOwner();
        Footprint storage footprint = _footprints[id];
        if (!footprint.set) revert NoFootprint();
        if (_designs[clubId][id]) revert AlreadyHasDesign();
        uint256 index = _pieces[clubId].length;
        if (index >= MAX_PIECES) revert ClubFull();
        uint256 size = 8 + 2 * uint256(_levels[clubId]);
        if (footprint.wall) {
            uint32 mask = _wallMask(footprint.w, x, y, rot, size);
            if (_walls[clubId][rot] & mask != 0) revert TileTaken();
            _walls[clubId][rot] |= mask;
        } else {
            uint256 mask = _placementMask(footprint.w, footprint.h, x, y, rot, size);
            if (_tiles[clubId] & mask != 0) revert TileTaken();
            _tiles[clubId] |= mask;
        }
        _designs[clubId][id] = true;
        _pieces[clubId].push(Piece(id, x, y, rot, footprint.wall));
        footprint.locked = true;
        emit FurniturePlaced(clubId, id, x, y, rot, index, footprint.wall);
        emit MetadataUpdate(clubId);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
        returns (bytes4)
    {
        revert BatchNotAccepted();
    }

    function _decodePlacement(bytes memory data) private pure returns (uint256 clubId, uint8 x, uint8 y, uint8 rot) {
        if (data.length != 128) revert BadPlacementData();
        // Decode full words first so noncanonical uint8 values also return our placement error.
        uint256 rawX;
        uint256 rawY;
        uint256 rawRot;
        (clubId, rawX, rawY, rawRot) = abi.decode(data, (uint256, uint256, uint256, uint256));
        if (rawX > 255 || rawY > 255 || rawRot > 255) revert BadPlacementData();
        return (clubId, uint8(rawX), uint8(rawY), uint8(rawRot));
    }

    function _wallMask(uint256 w, uint8 x, uint8 y, uint8 side, uint256 size) private pure returns (uint32 mask) {
        if (side > 1 || y != 0 || uint256(x) + w > size) revert OutOfRoom();
        mask = uint32(((uint256(1) << w) - 1) << x);
        if (side == 1 && mask & (uint32(1) << 4) != 0) revert BlocksDoor();
    }

    function _placementMask(uint256 w, uint256 h, uint8 x, uint8 y, uint8 rot, uint256 size)
        private
        pure
        returns (uint256 mask)
    {
        if (rot > 3) revert OutOfRoom();
        if (rot & 1 != 0) (w, h) = (h, w);
        if (uint256(x) + w > size || uint256(y) + h > size) revert OutOfRoom();
        for (uint256 row = y; row < uint256(y) + h; ++row) {
            mask |= ((uint256(1) << w) - 1) << (row * MAX_ROOM_SIZE + x);
        }
        if (mask & DOOR_MASK != 0) revert BlocksDoor();
    }

    function piecesOf(uint256 clubId) external view returns (Piece[] memory) {
        _clubOwner(clubId);
        return _pieces[clubId];
    }

    function pieceCount(uint256 clubId) external view returns (uint256) {
        _clubOwner(clubId);
        return _pieces[clubId].length;
    }

    /// @notice Door tiles are reserved, but not occupied furniture tiles.
    function tileTaken(uint256 clubId, uint8 x, uint8 y) external view returns (bool) {
        uint256 size = sizeOf(clubId);
        if (x >= size || y >= size) revert OutOfRoom();
        return _tiles[clubId] & (uint256(1) << (uint256(y) * MAX_ROOM_SIZE + x)) != 0;
    }

    function levelOf(uint256 clubId) public view returns (uint8) {
        _clubOwner(clubId);
        return _levels[clubId];
    }

    function sizeOf(uint256 clubId) public view returns (uint256) {
        return 8 + 2 * uint256(levelOf(clubId));
    }

    function upgradePrice(uint256 currentLevel) public view returns (uint256) {
        if (currentLevel == 1) return _level2Price;
        if (currentLevel == 2) return _level3Price;
        if (currentLevel == 3) return _level4Price;
        if (currentLevel == 4) return 0;
        revert BadLevel();
    }

    function hasDesign(uint256 clubId, uint256 id) external view returns (bool) {
        _clubOwner(clubId);
        return _designs[clubId][id];
    }

    function wallTaken(uint256 clubId, uint8 side, uint8 position) external view returns (bool) {
        uint256 size = sizeOf(clubId);
        if (side > 1 || position >= size) revert OutOfRoom();
        return _walls[clubId][side] & (uint32(1) << position) != 0;
    }

    function footprintOf(uint256 id) external view returns (uint8 w, uint8 h, bool set, bool locked, bool wall) {
        Footprint memory footprint = _footprints[id];
        return (footprint.w, footprint.h, footprint.set, footprint.locked, footprint.wall);
    }

    function setSaleOpen(bool open) external onlyOwner {
        saleOpen = open;
        emit SaleOpenSet(open);
    }

    function setFootprint(uint256 id, uint8 w, uint8 h, bool wall) external onlyOwner {
        if (_footprints[id].locked) revert FootprintLocked();
        if (w == 0 || h == 0 || w > 4 || h > 4 || (wall && h != 1)) revert BadFootprint();
        _footprints[id] = Footprint(w, h, true, false, wall);
        emit FootprintSet(id, w, h, wall);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        baseURI = newBaseURI;
        emit BaseURISet(newBaseURI);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    /// @notice Freezes the metadata prefix, not placements or unused furniture footprints.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        metadataFrozen = true;
        emit MetadataPermanentlyFrozen(baseURI);
        emit BatchMetadataUpdate(0, type(uint256).max);
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        _nonzero(receiver);
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        _setDefaultRoyalty(receiver, bps);
        emit RoyaltySet(receiver, bps);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _clubOwner(id);
        return string.concat(baseURI, Strings.toString(id), ".json");
    }

    function _clubOwner(uint256 clubId) private view returns (address holder) {
        holder = _ownerOf(clubId);
        if (holder == address(0)) revert NonexistentToken();
    }

    function _nonzero(address account) private pure returns (address) {
        if (account == address(0)) revert ZeroAddress();
        return account;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable, ERC2981, IERC165, ERC1155Holder)
        returns (bool)
    {
        return interfaceId == 0x49064906 || super.supportsInterface(interfaceId);
    }
}
