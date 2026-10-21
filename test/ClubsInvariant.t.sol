// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClubsOccupancy} from "./helpers/ClubsOccupancy.sol";
import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {PepeMock} from "./helpers/PepeMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";

/// @dev Independent cell-by-cell geometry oracle, with no production bitmap operations.
library ClubLayoutModel {
    function snapshot(OGClubClubs clubs, uint256 clubId, uint256 item) internal view returns (bytes32) {
        (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(item);
        return keccak256(abi.encode(clubs.piecesOf(clubId), w, h, set, locked, wall));
    }

    struct Board {
        bool[256] floor;
        bool[16][2] walls;
    }

    /// @dev At the end of a sequence, cross-check every public occupancy view with the same
    /// cell model used for the per-action whole-word storage checks.
    function readBoard(OGClubClubs clubs, uint256 clubId) internal view returns (Board memory board) {
        uint256 size = clubs.sizeOf(clubId);
        for (uint8 y; y < size; ++y) {
            for (uint8 x; x < size; ++x) {
                board.floor[uint256(x) + 16 * y] = clubs.tileTaken(clubId, x, y);
            }
            for (uint8 side; side < 2; ++side) {
                board.walls[side][y] = clubs.wallTaken(clubId, side, y);
            }
        }
    }

    /// @dev Encode the independent cell model only for comparison with storage. Geometry and
    /// overlap decisions still use booleans, not the production mask-building algorithm.
    function pack(Board memory board) internal pure returns (uint256 floor, uint256 walls) {
        for (uint256 cell; cell < 256; ++cell) {
            if (board.floor[cell]) floor |= uint256(1) << cell;
        }
        for (uint256 side; side < 2; ++side) {
            for (uint256 pos; pos < 16; ++pos) {
                if (board.walls[side][pos]) walls |= uint256(1) << (side * 32 + pos);
            }
        }
    }

    struct Placement {
        uint256 w;
        uint256 h;
        uint8 x;
        uint8 y;
        uint8 rot;
        bool wall;
    }

    function valid(Board memory board, Placement memory p, uint256 size) internal pure returns (bool) {
        if (p.wall) {
            if (p.rot > 1 || p.y != 0 || uint256(p.x) + p.w > size) return false;
            for (uint256 pos = p.x; pos < uint256(p.x) + p.w; ++pos) {
                if ((p.rot == 1 && pos == 4) || board.walls[p.rot][pos]) return false;
            }
        } else {
            if (p.rot > 3) return false;
            (uint256 w, uint256 h) = p.rot % 2 == 1 ? (p.h, p.w) : (p.w, p.h);
            if (uint256(p.x) + w > size || uint256(p.y) + h > size) return false;
            for (uint256 x = p.x; x < uint256(p.x) + w; ++x) {
                for (uint256 y = p.y; y < uint256(p.y) + h; ++y) {
                    if ((y == 4 && x < 2) || board.floor[x + 16 * y]) return false;
                }
            }
        }
        return true;
    }

    function occupy(Board memory board, Placement memory p) internal pure returns (Board memory) {
        if (p.wall) {
            for (uint256 pos = p.x; pos < uint256(p.x) + p.w; ++pos) {
                board.walls[p.rot][pos] = true;
            }
        } else {
            (uint256 w, uint256 h) = p.rot % 2 == 1 ? (p.h, p.w) : (p.w, p.h);
            for (uint256 x = p.x; x < uint256(p.x) + w; ++x) {
                for (uint256 y = p.y; y < uint256(p.y) + h; ++y) {
                    board.floor[x + 16 * y] = true;
                }
            }
        }
        return board;
    }
}

contract ClubsLayoutFuzzTest is ClubsTestBase {
    ClubsOccupancy.Slots private occupancySlots;

    function setUp() public override {
        super.setUp();
        occupancySlots = ClubsOccupancy.locate(stdstore, clubs, 1);
    }

    function testFuzz_RandomLevelsWallsRotationsAndDesignsMatchIndependentModel(bytes32 seed, uint8 levelSeed) public {
        uint8 level = 1 + levelSeed % 4;
        vm.startPrank(alice);
        for (uint8 l = 1; l < level; ++l) {
            clubs.upgradeClub(1);
        }
        vm.stopPrank();
        ClubLayoutModel.Board memory board;
        bool[24] memory designs;
        for (uint256 item; item < 24; ++item) {
            uint256 r = uint256(keccak256(abi.encode(seed, item)));
            bool wall = r % 2 == 0;
            clubs.setFootprint(item + 10, uint8(1 + (r >> 8) % 4), wall ? 1 : uint8(1 + (r >> 16) % 4), wall);
        }
        uint256 successes;
        for (uint256 i; i < 48; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i, "placement")));
            uint256 item = r % 24;
            (uint8 w, uint8 h,,, bool wall) = clubs.footprintOf(item + 10);
            ClubLayoutModel.Placement memory p = ClubLayoutModel.Placement(
                w,
                h,
                uint8((r >> 8) % 18),
                wall && r % 3 != 0 ? 0 : uint8((r >> 16) % 18),
                uint8((r >> 24) % (wall ? 3 : 5)),
                wall
            );
            stock(alice, item + 10, 1);
            bool expected = !designs[item] && ClubLayoutModel.valid(board, p, clubs.sizeOf(1));
            bytes32 beforeState = ClubLayoutModel.snapshot(clubs, 1, item + 10);
            uint256 held = furniture.balanceOf(address(clubs), item + 10);
            uint256 owned = furniture.balanceOf(alice, item + 10);
            vm.prank(alice);
            (bool ok,) = address(furniture)
                .call(
                    abi.encodeCall(
                        furniture.safeTransferFrom,
                        (alice, address(clubs), item + 10, 1, abi.encode(uint256(1), p.x, p.y, p.rot))
                    )
                );
            assertEq(ok, expected, "geometry/design model disagrees");
            if (ok) {
                board = ClubLayoutModel.occupy(board, p);
                designs[item] = true;
                ++successes;
            } else {
                assertEq(ClubLayoutModel.snapshot(clubs, 1, item + 10), beforeState);
            }
            assertEq(furniture.balanceOf(address(clubs), item + 10), held + (ok ? 1 : 0));
            assertEq(furniture.balanceOf(alice, item + 10), owned - (ok ? 1 : 0));
            assertEq(clubs.hasDesign(1, item + 10), designs[item]);
            assertEq(clubs.pieceCount(1), successes);
            _checkStoredBoard(board);
        }
        _checkBoard(board);
    }

    function _checkStoredBoard(ClubLayoutModel.Board memory board) private view {
        (uint256 floor, uint256 walls) = ClubsOccupancy.read(clubs, occupancySlots);
        (uint256 expectedFloor, uint256 expectedWalls) = ClubLayoutModel.pack(board);
        assertEq(floor, expectedFloor, "floor occupancy disagrees with model");
        assertEq(walls, expectedWalls, "wall occupancy disagrees with model");
    }

    function _checkBoard(ClubLayoutModel.Board memory board) private view {
        assertEq(
            keccak256(abi.encode(ClubLayoutModel.readBoard(clubs, 1))),
            keccak256(abi.encode(board)),
            "occupancy views disagree with the independent model"
        );
        assertFalse(board.floor[64]);
        assertFalse(board.floor[65]);
        assertFalse(board.walls[1][4]);
    }
}

contract ClubsHandler is Test {
    MockOG public immutable token;
    OGClubFurniture public immutable furniture;
    OGClubClubs public immutable clubs;
    PepeMock public immutable pepes;
    address public immutable admin;
    address[3] public actors;
    uint256 public ghostPaid;
    uint256 public ghostBurned;
    uint256 public ghostToVault;
    uint256 public ghostPieces;
    uint256 public pepeNonce;
    mapping(uint256 => uint256) public piecesByItem;
    mapping(uint256 => uint256) public mintCount;
    mapping(uint256 => mapping(uint256 => bool)) public design;
    mapping(uint256 => ClubLayoutModel.Board) private _boards;
    mapping(uint256 => ClubsOccupancy.Slots) private _occupancySlots;

    constructor(MockOG token_, OGClubFurniture furniture_, OGClubClubs clubs_, address admin_) {
        token = token_;
        furniture = furniture_;
        clubs = clubs_;
        admin = admin_;
        pepes = PepeMock(address(clubs_.pepes()));
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("club actor ", vm.toString(i)));
        }
    }

    function mint(uint8 payerSeed) external {
        if (clubs.totalSupply() >= 8) return;
        address payer = actors[payerSeed % 3];
        uint256 id = (++pepeNonce) * 101;
        pepes.mint(payer, id);
        uint256 cost = clubs.price();
        _fund(payer, cost);
        bool open = clubs.saleOpen();
        vm.prank(payer);
        if (!open) {
            vm.expectRevert(OGClubClubs.SaleClosed.selector);
            clubs.mintClub(id);
            assertFalse(clubs.clubsMinted(id));
        } else {
            assertEq(clubs.mintClub(id), id);
            assertEq(clubs.ownerOf(id), payer);
            _occupancySlots[id] = ClubsOccupancy.locate(stdstore, clubs, id);
            ++mintCount[id];
            _payment(cost);
        }
    }

    function upgrade(uint8 clubSeed, uint8 payerSeed) external {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        address holder = clubs.ownerOf(id);
        address payer = payerSeed % 2 == 0 ? holder : actors[payerSeed % 3];
        uint8 level = clubs.levelOf(id);
        uint256 cost = clubs.upgradePrice(level);
        _fund(payer, cost);
        bytes32 layout = keccak256(abi.encode(clubs.piecesOf(id)));
        uint256 burned = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 toVault = token.balanceOf(clubs.vault());
        vm.prank(payer);
        if (payer != holder) {
            vm.expectRevert(OGClubClubs.NotClubOwner.selector);
            clubs.upgradeClub(id);
        } else if (level == 4) {
            vm.expectRevert(OGClubClubs.MaxLevel.selector);
            clubs.upgradeClub(id);
        } else {
            clubs.upgradeClub(id);
            _payment(cost);
            assertEq(clubs.levelOf(id), level + 1);
            assertEq(keccak256(abi.encode(clubs.piecesOf(id))), layout);
            return;
        }
        assertEq(clubs.levelOf(id), level);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), burned);
        assertEq(token.balanceOf(clubs.vault()), toVault);
    }

    function place(uint8 clubSeed, uint8 fromSeed, uint8 itemSeed, uint8 xSeed, uint8 ySeed, uint8 rotSeed) external {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        address from = fromSeed % 2 == 0 ? clubs.ownerOf(id) : actors[fromSeed % 3];
        uint256 item = 1 + itemSeed % 8;
        (uint8 w, uint8 h,,, bool wall) = clubs.footprintOf(item);
        ClubLayoutModel.Placement memory p = ClubLayoutModel.Placement(
            w, h, xSeed % 18, wall && ySeed % 3 != 0 ? 0 : ySeed % 18, rotSeed % (wall ? 3 : 5), wall
        );
        _place(id, from, item, p);
    }

    function _place(uint256 id, address from, uint256 item, ClubLayoutModel.Placement memory p) private {
        bool expected =
            clubs.ownerOf(id) == from && !design[id][item] && ClubLayoutModel.valid(_boards[id], p, clubs.sizeOf(id));
        _stock(from, item);
        uint256 beforeHeld = furniture.balanceOf(address(clubs), item);
        uint256 beforeOwned = furniture.balanceOf(from, item);
        bytes32 layout = ClubLayoutModel.snapshot(clubs, id, item);
        vm.prank(from);
        (bool ok,) = address(furniture)
            .call(
                abi.encodeCall(
                    furniture.safeTransferFrom, (from, address(clubs), item, 1, abi.encode(id, p.x, p.y, p.rot))
                )
            );
        assertEq(ok, expected);
        if (ok) {
            _boards[id] = ClubLayoutModel.occupy(_boards[id], p);
            design[id][item] = true;
            ++ghostPieces;
            ++piecesByItem[item];
        } else {
            assertEq(furniture.balanceOf(address(clubs), item), beforeHeld);
            assertEq(furniture.balanceOf(from, item), beforeOwned);
            assertEq(ClubLayoutModel.snapshot(clubs, id, item), layout);
        }
    }

    function transferClub(uint8 clubSeed, uint8 toSeed) external {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        address holder = clubs.ownerOf(id);
        bytes32 layout = keccak256(abi.encode(clubs.piecesOf(id)));
        vm.prank(holder);
        clubs.transferFrom(holder, actors[toSeed % 3], id);
        assertEq(keccak256(abi.encode(clubs.piecesOf(id))), layout);
    }

    function transferPepeAndTryAgain(uint8 clubSeed, uint8 toSeed) external {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        address from = pepes.ownerOf(id);
        address to = actors[toSeed % 3];
        vm.prank(from);
        pepes.transferFrom(from, to, id);
        uint256 supply = clubs.totalSupply();
        bytes4 expected = clubs.saleOpen() ? OGClubClubs.AlreadyMinted.selector : OGClubClubs.SaleClosed.selector;
        vm.prank(to);
        vm.expectRevert(expected);
        clubs.mintClub(id);
        assertEq(clubs.totalSupply(), supply);
    }

    function sale(bool open) external {
        vm.prank(admin);
        clubs.setSaleOpen(open);
    }

    function occupancy(uint256 id) external view returns (uint256 floor, uint256 walls) {
        return ClubsOccupancy.read(clubs, _occupancySlots[id]);
    }

    function expectedBoardHash(uint256 id) external view returns (bytes32) {
        return keccak256(abi.encode(_boards[id]));
    }

    function _payment(uint256 cost) private {
        ghostPaid += cost;
        ghostBurned += cost / 2;
        ghostToVault += cost - cost / 2;
    }

    function _fund(address payer, uint256 cost) private {
        token.mint(payer, cost);
        vm.prank(payer);
        token.approve(address(clubs), cost);
    }

    function _stock(address to, uint256 item) private {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = item;
        amounts[0] = 1;
        furniture.mintBatch(to, ids, amounts);
    }
}

contract ClubsInvariantTest is Test {
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubFarmVault internal vault;
    OGClubClubs internal clubs;
    ClubsHandler internal handler;
    PepeMock internal pepes;

    function setUp() public {
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), address(this));
        vault = new OGClubFarmVault(token, address(this));
        pepes = new PepeMock();
        clubs = new OGClubClubs(
            token,
            address(vault),
            100_000e18 + 1,
            IERC1155(address(furniture)),
            address(this),
            address(this),
            pepes,
            IDelegateRegistry(address(0)),
            OGClubClubs.UpgradePrices(200_000e18 + 1, 400_000e18 + 3, 800_000e18 + 5)
        );
        for (uint256 i = 1; i <= 8; ++i) {
            clubs.setFootprint(i, uint8(1 + (i - 1) % 4), i > 4 ? 1 : 2, i > 4);
        }
        clubs.setSaleOpen(true);
        handler = new ClubsHandler(token, furniture, clubs, address(this));
        furniture.grantMinter(address(handler));
        handler.mint(0);
        handler.place(0, 0, 0, 2, 2, 0);
        handler.place(0, 0, 4, 0, 0, 0);
        handler.upgrade(0, 0);
        handler.transferClub(0, 1);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.place.selector;
        selectors[2] = handler.transferClub.selector;
        selectors[3] = handler.sale.selector;
        selectors[4] = handler.upgrade.selector;
        selectors[5] = handler.transferPepeAndTryAgain.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_PaymentsNeverRemainInClubsAndAllMintUpgradeSplitsAreConserved() public view {
        assertEq(token.balanceOf(address(clubs)), 0);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), handler.ghostBurned());
        assertEq(token.balanceOf(address(vault)), handler.ghostToVault());
        assertEq(handler.ghostBurned() + handler.ghostToVault(), handler.ghostPaid());
        uint256 total;
        for (uint256 i; i < clubs.totalSupply(); ++i) {
            uint256 id = clubs.tokenByIndex(i);
            assertTrue(clubs.clubsMinted(id));
            assertEq(handler.mintCount(id), 1);
            assertTrue(pepes.ownerOf(id) != address(0));
            uint8 level = clubs.levelOf(id);
            assertGe(level, 1);
            assertLe(level, 4);
            total += clubs.price();
            for (uint8 l = 1; l < level; ++l) {
                total += clubs.upgradePrice(l);
            }
        }
        assertEq(handler.ghostPaid(), total);
    }

    function invariant_LayoutsFitDoorsRemainClearDesignsAreUniqueAndCustodyMatches() public view {
        uint256 total;
        uint256[9] memory perItem;
        for (uint256 c; c < clubs.totalSupply(); ++c) {
            uint256 id = clubs.tokenByIndex(c);
            uint256 size = clubs.sizeOf(id);
            OGClubClubs.Piece[] memory pieces = clubs.piecesOf(id);
            total += pieces.length;
            assertEq(clubs.pieceCount(id), pieces.length);
            assertLe(pieces.length, 285);
            ClubLayoutModel.Board memory board;
            bool[9] memory seen;
            for (uint256 i; i < pieces.length; ++i) {
                OGClubClubs.Piece memory piece = pieces[i];
                ClubLayoutModel.Placement memory p = _modelPiece(piece);
                assertFalse(seen[piece.furnitureId]);
                seen[piece.furnitureId] = true;
                assertTrue(clubs.hasDesign(id, piece.furnitureId));
                assertTrue(handler.design(id, piece.furnitureId));
                assertTrue(ClubLayoutModel.valid(board, p, size));
                board = ClubLayoutModel.occupy(board, p);
                ++perItem[piece.furnitureId];
            }
            (uint256 floor, uint256 walls) = handler.occupancy(id);
            (uint256 expectedFloor, uint256 expectedWalls) = ClubLayoutModel.pack(board);
            assertEq(floor, expectedFloor, "floor occupancy disagrees with pieces");
            assertEq(walls, expectedWalls, "wall occupancy disagrees with pieces");
            assertEq(keccak256(abi.encode(board)), handler.expectedBoardHash(id), "pieces disagree with model");
        }
        for (uint256 item = 1; item <= 8; ++item) {
            assertEq(furniture.balanceOf(address(clubs), item), perItem[item]);
            assertEq(perItem[item], handler.piecesByItem(item));
        }
        assertEq(total, handler.ghostPieces());
        assertGt(total, 0);
    }

    function afterInvariant() external view {
        // Public getter integration remains exhaustive, once per random history. Whole storage
        // words (including cells outside the current room) are checked after every action above.
        for (uint256 i; i < clubs.totalSupply(); ++i) {
            uint256 id = clubs.tokenByIndex(i);
            assertEq(
                keccak256(abi.encode(ClubLayoutModel.readBoard(clubs, id))),
                handler.expectedBoardHash(id),
                "public occupancy views disagree with model"
            );
        }
    }

    function _modelPiece(OGClubClubs.Piece memory piece) private view returns (ClubLayoutModel.Placement memory) {
        (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(piece.furnitureId);
        assertTrue(set && locked);
        assertEq(piece.wall, wall);
        return ClubLayoutModel.Placement(w, h, piece.x, piece.y, piece.rot, wall);
    }
}
