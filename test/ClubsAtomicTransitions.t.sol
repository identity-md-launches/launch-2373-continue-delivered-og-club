// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {PepeMock} from "./helpers/PepeMocks.sol";
import {TestToken, NoReturnToken} from "./helpers/TokenMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev All callback actions occur inside the mint transaction, including the final rejection.
contract ClubLayoutRejector is ERC1155Holder, IERC721Receiver {
    error RejectAfterPlacement();

    OGClubClubs internal immutable clubs;
    address internal immutable recipient;
    bool internal reject;

    constructor(OGClubClubs clubs_, address recipient_) {
        clubs = clubs_;
        recipient = recipient_;
    }

    function approvePayment() external {
        clubs.token().approve(address(clubs), clubs.price());
    }

    function mint(uint256 id, bool reject_) external {
        reject = reject_;
        clubs.mintClub(id);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(clubs), "unexpected NFT");
        clubs.furniture().safeTransferFrom(address(this), address(clubs), 100, 1, abi.encode(id, 9, 9, 0));
        clubs.furniture().safeTransferFrom(address(this), address(clubs), 101, 1, abi.encode(id, 9, 0, 1));
        clubs.transferFrom(address(this), recipient, id);
        clubs.pepes().transferFrom(address(this), recipient, id);
        if (reject) revert RejectAfterPlacement();
        return this.onERC721Received.selector;
    }
}

/// @dev The callback is a funded Pepe holder and club operator. Authorization cannot mask a missing guard.
contract ClubAuthorizedReentryToken is ERC20, IERC721Receiver {
    address internal target;
    bytes internal payload;
    bool internal insideCallback;
    uint256 public attempts;
    bytes public firstError;
    bytes public secondError;

    constructor() ERC20("Callback probe", "PROBE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approveFromToken(address spender) external {
        _approve(address(this), spender, type(uint256).max);
    }

    function arm(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
        attempts = 0;
        delete firstError;
        delete secondError;
    }

    function execute(address target_, bytes memory payload_) external {
        (bool ok, bytes memory data) = target_.call(payload_);
        if (!ok) {
            assembly ("memory-safe") { revert(add(data, 32), mload(data)) }
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (target != address(0) && !insideCallback) {
            insideCallback = true;
            (bool ok, bytes memory data) = target.call(payload);
            require(!ok, "reentrant operation succeeded");
            if (++attempts == 1) firstError = data;
            else secondError = data;
            insideCallback = false;
        }
        return true;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @dev Unlike a token that returns false immediately, this exercises rollback of already changed balances.
contract ClubLateFalseToken is ERC20 {
    uint256 public transferNumber;
    uint256 internal failAt;

    constructor() ERC20("Late failure", "LATE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint256 failAt_) external {
        transferNumber = 0;
        failAt = failAt_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        return ++transferNumber != failAt;
    }
}

contract ClubsAtomicTransitionsTest is ClubsTestBase {
    function test_ReceiverRejectionRollsBackPlacementsLocksPaymentsAndBothNFTTransfers() public {
        clubs.setFootprint(100, 1, 1, false);
        clubs.setFootprint(101, 1, 1, true);
        ClubLayoutRejector receiver = new ClubLayoutRejector(clubs, bob);
        pepes.mint(address(receiver), 777);
        token.mint(address(receiver), PRICE);
        stock(address(receiver), 100, 1);
        stock(address(receiver), 101, 1);
        receiver.approvePayment();
        uint256 burnBefore = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 vaultBefore = token.balanceOf(address(vault));
        uint256 supplyBefore = clubs.totalSupply();

        vm.expectRevert(ClubLayoutRejector.RejectAfterPlacement.selector);
        receiver.mint(777, true);

        assertEq(pepes.ownerOf(777), address(receiver));
        assertFalse(clubs.clubsMinted(777));
        assertEq(clubs.totalSupply(), supplyBefore);
        assertEq(clubs.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(receiver)), PRICE);
        assertEq(token.allowance(address(receiver), address(clubs)), PRICE);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), burnBefore);
        assertEq(token.balanceOf(address(vault)), vaultBefore);
        assertEq(token.balanceOf(address(clubs)), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 777));
        clubs.ownerOf(777);
        for (uint256 item = 100; item <= 101; ++item) {
            (,,, bool locked,) = clubs.footprintOf(item);
            assertFalse(locked, "rejected mint permanently locked a design");
            assertEq(furniture.balanceOf(address(receiver), item), 1);
            assertEq(furniture.balanceOf(address(clubs), item), 0);
        }

        // The same input is recoverable; no phantom layout or consumed mint right survives rejection.
        receiver.mint(777, false);
        assertEq(pepes.ownerOf(777), bob);
        assertEq(clubs.ownerOf(777), bob);
        assertEq(clubs.totalSupply(), supplyBefore + 1);
        assertTrue(clubs.clubsMinted(777));
        assertEq(clubs.levelOf(777), 1);
        assertEq(clubs.pieceCount(777), 2);
        assertTrue(clubs.tileTaken(777, 9, 9));
        assertTrue(clubs.wallTaken(777, 1, 9));
        assertFalse(clubs.wallTaken(777, 0, 9));
        for (uint256 item = 100; item <= 101; ++item) {
            (,,, bool locked,) = clubs.footprintOf(item);
            assertTrue(locked);
            assertTrue(clubs.hasDesign(777, item));
            assertEq(furniture.balanceOf(address(clubs), item), 1);
        }
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), burnBefore + PRICE / 2);
        assertEq(token.balanceOf(address(vault)), vaultBefore + PRICE - PRICE / 2);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        clubs.mintClub(777);
    }

    function _withToken(IERC20 payment) private returns (OGClubClubs c) {
        c = new OGClubClubs(
            payment,
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
    }

    function test_AuthorizedFundedCallbacksCannotCrossReenterEitherPaymentEntryPoint() public {
        ClubAuthorizedReentryToken probe = new ClubAuthorizedReentryToken();
        OGClubClubs c = _withToken(probe);
        probe.mint(alice, 10_000);
        probe.mint(address(probe), 10_000);
        probe.approveFromToken(address(c));
        pepes.mint(address(probe), 777);
        vm.startPrank(alice);
        probe.approve(address(c), 10_000);
        c.setApprovalForAll(address(probe), true);
        vm.stopPrank();

        probe.arm(address(c), abi.encodeCall(c.mintClub, (777)));
        vm.prank(alice);
        c.mintClub(1);
        _assertGuard(probe);
        assertFalse(c.clubsMinted(777));

        // During mint, the token already has operator rights to the caller's existing club.
        probe.arm(address(c), abi.encodeCall(c.upgradeClub, (1)));
        vm.prank(alice);
        c.mintClub(2);
        _assertGuard(probe);
        assertEq(c.levelOf(1), 1);

        vm.prank(alice);
        c.upgradeClub(1);
        assertEq(probe.attempts(), 4);
        assertEq(probe.secondError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(c.levelOf(1), 2);

        probe.arm(address(c), abi.encodeCall(c.mintClub, (777)));
        vm.prank(alice);
        c.upgradeClub(1);
        _assertGuard(probe);
        assertFalse(c.clubsMinted(777));
        assertEq(probe.balanceOf(address(probe)), 10_000);

        // Positive controls prove that this callback actor really can perform both actions outside reentry.
        probe.arm(address(0), "");
        probe.execute(address(c), abi.encodeCall(c.mintClub, (777)));
        probe.execute(address(c), abi.encodeCall(c.upgradeClub, (1)));
        assertEq(c.ownerOf(777), address(probe));
        assertEq(c.levelOf(1), 4);
        assertEq(probe.balanceOf(address(probe)), 10_000 - 101 - 801);
        assertEq(probe.balanceOf(address(c)), 0);
    }

    function _assertGuard(ClubAuthorizedReentryToken probe) private view {
        bytes memory expected = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(probe.attempts(), 2);
        assertEq(probe.firstError(), expected);
        assertEq(probe.secondError(), expected);
    }

    function test_FalseAfterEitherTransferRollsBackMintAndEveryUpgradeAndCanBeRetried() public {
        ClubLateFalseToken badToken = new ClubLateFalseToken();
        OGClubClubs c = _withToken(badToken);
        badToken.mint(alice, 1504); // 101 + 201 + 401 + 801, exact full lifecycle budget.
        vm.prank(alice);
        badToken.approve(address(c), 1504);
        for (uint256 level; level < 4; ++level) {
            for (uint256 leg = 1; leg <= 2; ++leg) {
                badToken.configure(leg);
                bytes32 beforeState = _paymentState(c, badToken, level != 0);
                vm.prank(alice);
                vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(badToken)));
                if (level == 0) c.mintClub(1);
                else c.upgradeClub(1);
                assertEq(_paymentState(c, badToken, level != 0), beforeState);
                assertEq(badToken.transferNumber(), 0, "token-side changes survived the reverted payment");
            }
            badToken.configure(0);
            vm.prank(alice);
            if (level == 0) c.mintClub(1);
            else c.upgradeClub(1);
            assertEq(c.levelOf(1), level + 1);
        }
        assertEq(badToken.balanceOf(alice), 0);
        assertEq(badToken.allowance(alice, address(c)), 0);
        assertEq(badToken.balanceOf(c.BURN_ADDRESS()), 750);
        assertEq(badToken.balanceOf(address(vault)), 754);
    }

    function _paymentState(OGClubClubs c, IERC20 payment, bool exists) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                payment.balanceOf(alice),
                payment.allowance(alice, address(c)),
                payment.balanceOf(c.BURN_ADDRESS()),
                payment.balanceOf(address(vault)),
                payment.balanceOf(address(c)),
                c.clubsMinted(1),
                c.totalSupply(),
                exists ? c.levelOf(1) : 0
            )
        );
    }
}

contract ClubsPriceBoundaryTest is Test {
    event ClubUpgraded(uint256 indexed clubId, uint8 newLevel, address indexed payer, uint256 burned, uint256 toVault);
    event MetadataUpdate(uint256 tokenId);

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_IndependentPricesChargeExactCallerBalances(uint256 a, uint256 b, uint256 c, uint256 d) public {
        // Four payments can jointly reach almost the entire uint256 domain without overflowing the test token supply.
        uint256 cap = type(uint256).max / 4;
        uint256[4] memory prices = [bound(a, 1, cap), bound(b, 1, cap), bound(c, 1, cap), bound(d, 1, cap)];
        _checkPayments(prices, false);
    }

    function test_MaximumTotalSupplyAndAlmostMaximumUpgradePrice() public {
        _checkPayments([uint256(1), 1, 1, type(uint256).max - 3], false);
    }

    function test_OneWeiMintAndUpgradesWorkWithNoReturnToken() public {
        _checkPayments([uint256(1), 1, 1, 1], true);
    }

    function _checkPayments(uint256[4] memory prices, bool noReturn) private {
        address payer = makeAddr("price payer");
        address revenue = makeAddr("price revenue");
        IERC20 payment;
        if (noReturn) payment = IERC20(address(new NoReturnToken()));
        else payment = new TestToken(18);
        PepeMock pepes = new PepeMock();
        OGClubFurniture furniture = new OGClubFurniture(address(this), revenue);
        OGClubClubs clubs = new OGClubClubs(
            payment,
            revenue,
            prices[0],
            IERC1155(address(furniture)),
            address(this),
            revenue,
            pepes,
            IDelegateRegistry(address(0)),
            OGClubClubs.UpgradePrices(prices[1], prices[2], prices[3])
        );
        clubs.setSaleOpen(true);
        pepes.mint(payer, type(uint256).max);
        uint256 total = prices[0] + prices[1] + prices[2] + prices[3];
        if (noReturn) NoReturnToken(address(payment)).mint(payer, total);
        else TestToken(address(payment)).mint(payer, total);
        uint256 paid;
        uint256 burned;
        for (uint8 i; i < 4; ++i) {
            _payNext(clubs, payer, prices[i], i, noReturn);
            paid += prices[i];
            burned += prices[i] / 2;
            assertEq(payment.balanceOf(payer), total - paid);
            assertEq(payment.allowance(payer, address(clubs)), 0);
            assertEq(payment.balanceOf(clubs.BURN_ADDRESS()), burned);
            assertEq(payment.balanceOf(revenue), paid - burned);
            assertEq(payment.balanceOf(address(clubs)), 0);
            assertEq(clubs.levelOf(type(uint256).max), i + 1);
            assertEq(clubs.sizeOf(type(uint256).max), 10 + 2 * uint256(i));
        }
        assertEq(paid, total);
        assertEq(clubs.upgradePrice(4), 0);
        vm.prank(payer);
        vm.expectRevert(OGClubClubs.MaxLevel.selector);
        clubs.upgradeClub(type(uint256).max);
    }

    function _payNext(OGClubClubs clubs, address payer, uint256 price, uint8 level, bool noReturn) private {
        IERC20 payment = clubs.token();
        vm.prank(payer);
        if (noReturn) NoReturnToken(address(payment)).approve(address(clubs), price);
        else payment.approve(address(clubs), price);
        if (level != 0) {
            assertEq(clubs.upgradePrice(level), price);
            vm.expectEmit(true, true, false, true, address(clubs));
            emit ClubUpgraded(type(uint256).max, level + 1, payer, price / 2, price - price / 2);
            vm.expectEmit(false, false, false, true, address(clubs));
            emit MetadataUpdate(type(uint256).max);
        }
        vm.prank(payer);
        if (level == 0) assertEq(clubs.mintClub(type(uint256).max), type(uint256).max);
        else clubs.upgradeClub(type(uint256).max);
    }
}
