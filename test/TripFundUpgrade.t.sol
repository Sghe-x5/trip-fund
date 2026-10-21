pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TripFundCore} from "../src/TripFundCore.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TripToken} from "../src/TripToken.sol";

contract TripFundUpgradeTest is Test {
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    TripToken internal token;
    TripFundV1 internal implementationV1;
    TripFundV2 internal implementationV2;
    TransparentUpgradeableProxy internal proxy;
    ProxyAdmin internal admin;
    TripFundV1 internal v1;
    TripFundV2 internal v2;
    address internal owner = makeAddr("owner");
    address internal organizer = makeAddr("organizer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal friend = makeAddr("friend");
    uint256 internal end;
    uint256 internal constant GOAL = 100 ether;

    event ContributedFor(address indexed payer, address indexed beneficiary, uint256 amount);

    function setUp() public {
        vm.warp(1_000_000);
        end = block.timestamp + 7 days;
        token = new TripToken(address(this), 10_000 ether);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertTrue(token.transfer(bob, 1_000 ether));
        implementationV1 = new TripFundV1();
        implementationV2 = new TripFundV2();
        proxy = new TransparentUpgradeableProxy(
            address(implementationV1),
            owner,
            abi.encodeCall(TripFundV1.initialize, (address(token), organizer, GOAL, end))
        );
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
        v1 = TripFundV1(address(proxy));
        v2 = TripFundV2(address(proxy));
        vm.prank(alice);
        token.approve(address(proxy), type(uint256).max);
        vm.prank(bob);
        token.approve(address(proxy), type(uint256).max);
    }

    function _upgrade() internal {
        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), "");
    }

    function testUpgradePreservesAllStateAndRefundsFriend() public {
        vm.prank(alice);
        v1.contribute(10 ether);
        assertTrue(token.transfer(address(proxy), 7 ether));
        address originalProxy = address(v1);
        address originalAdmin = address(admin);
        vm.warp(end - 100);
        _upgrade();
        assertEq(address(v2), originalProxy);
        assertEq(
            address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), address(implementationV2)
        );
        assertEq(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))), originalAdmin);
        assertEq(admin.owner(), owner);
        assertEq(address(v2.token()), address(token));
        assertEq(v2.organizer(), organizer);
        assertEq(v2.goal(), GOAL);
        assertEq(v2.deadline(), end);
        assertEq(v2.contributions(alice), 10 ether);
        assertEq(v2.contributions(friend), 0);
        assertEq(v2.totalRaised(), 10 ether);
        assertFalse(v2.withdrawn());
        assertEq(token.balanceOf(address(proxy)), 17 ether);
        assertEq(token.allowance(alice, address(proxy)), type(uint256).max);
        vm.startPrank(bob);
        v2.contributeFor(friend, 20 ether);
        v2.contributeFor(friend, 5 ether);
        vm.stopPrank();
        vm.prank(alice);
        v2.contribute(3 ether);
        assertEq(v2.contributions(alice), 13 ether);
        assertEq(v2.contributions(friend), 25 ether);
        assertEq(v2.contributions(bob), 0);
        assertEq(v2.totalRaised(), 38 ether);
        assertEq(token.balanceOf(bob), 975 ether);
        assertEq(token.balanceOf(friend), 0);
        vm.warp(end);
        vm.prank(bob);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        v2.refund();
        vm.prank(friend);
        v2.refund();
        vm.prank(alice);
        v2.refund();
        assertEq(token.balanceOf(friend), 25 ether);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(bob), 975 ether);
        assertEq(token.balanceOf(address(proxy)), 7 ether);
        assertEq(v2.totalRaised(), 38 ether);
        assertEq(v2.contributions(friend), 0);
        assertEq(v2.contributions(alice), 0);
        vm.prank(friend);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        v2.refund();
    }

    function testOnlyProxyAdminOwnerCanUpgrade() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), "");
        assertEq(
            address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), address(implementationV1)
        );
        vm.prank(organizer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, organizer));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implementationV2), "");
        _upgrade();
        assertEq(
            address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), address(implementationV2)
        );
    }

    function testDirectProxyUpgradeIsRejected() public {
        vm.prank(alice);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(proxy)).upgradeToAndCall(address(implementationV2), "");
        assertEq(
            address(uint160(uint256(vm.load(address(proxy), IMPLEMENTATION_SLOT)))), address(implementationV1)
        );
    }

    function testProxyCannotBeInitializedTwiceBeforeOrAfterUpgrade() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v1.initialize(address(token), alice, 1, end + 1);
        _upgrade();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(address(token), alice, 1, end + 1);
        assertEq(v2.organizer(), organizer);
        assertEq(v2.goal(), GOAL);
        assertEq(v2.deadline(), end);
    }

    function testBothImplementationsRejectDirectInitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV1.initialize(address(token), organizer, GOAL, end);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementationV2.initialize(address(token), organizer, GOAL, end);
    }

    function testContributeForChargesPayerAndEmitsEvent() public {
        _upgrade();
        vm.expectEmit(true, true, false, true, address(proxy));
        emit ContributedFor(alice, friend, 10 ether);
        vm.prank(alice);
        v2.contributeFor(friend, 10 ether);
        assertEq(token.balanceOf(alice), 990 ether);
        assertEq(token.balanceOf(friend), 0);
        assertEq(v2.contributions(friend), 10 ether);
        assertEq(v2.contributions(alice), 0);
        assertEq(v2.totalRaised(), 10 ether);
        assertEq(token.balanceOf(address(proxy)), 10 ether);
    }

    function testContributeForAggregatesWithOrdinaryContributions() public {
        _upgrade();
        vm.startPrank(alice);
        v2.contribute(2 ether);
        v2.contributeFor(alice, 3 ether);
        vm.stopPrank();
        vm.prank(bob);
        v2.contributeFor(alice, 4 ether);
        assertEq(v2.contributions(alice), 9 ether);
        assertEq(v2.totalRaised(), 9 ether);
    }

    function testContributeForZeroBeneficiaryRollsBack() public {
        _upgrade();
        vm.prank(alice);
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        v2.contributeFor(address(0), 10 ether);
        _assertNoContribution();
    }

    function testContributeForZeroAmountRollsBack() public {
        _upgrade();
        vm.prank(alice);
        vm.expectRevert(TripFundCore.ZeroAmount.selector);
        v2.contributeFor(friend, 0);
        _assertNoContribution();
    }

    function testContributeForDeadlineBoundary() public {
        _upgrade();
        vm.warp(end - 1);
        vm.prank(alice);
        v2.contributeFor(friend, 10 ether);
        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert(TripFundCore.FundingClosed.selector);
        v2.contributeFor(friend, 5 ether);
        assertEq(v2.contributions(friend), 10 ether);
        assertEq(v2.totalRaised(), 10 ether);
        assertEq(token.balanceOf(alice), 990 ether);
    }

    function testContributeForUsesPayerAllowance() public {
        _upgrade();
        vm.prank(alice);
        token.approve(address(proxy), 0);
        vm.prank(friend);
        token.approve(address(proxy), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(proxy), 0, 10 ether
            )
        );
        v2.contributeFor(friend, 10 ether);
        _assertNoContribution();
    }

    function testContributeForInsufficientPayerBalanceRollsBack() public {
        _upgrade();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000 ether, 1_001 ether
            )
        );
        v2.contributeFor(friend, 1_001 ether);
        _assertNoContribution();
    }

    function testContributeForSuccessPaysOrganizerAndRejectsFriendRefund() public {
        _upgrade();
        vm.prank(alice);
        v2.contributeFor(friend, GOAL);
        vm.warp(end);
        vm.prank(friend);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        v2.refund();
        vm.prank(organizer);
        v2.withdraw();
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(proxy)), 0);
        assertEq(v2.totalRaised(), GOAL);
    }

    function _assertNoContribution() internal view {
        assertEq(v2.totalRaised(), 0);
        assertEq(v2.contributions(friend), 0);
        assertEq(v2.contributions(alice), 0);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(friend), 0);
        assertEq(token.balanceOf(address(proxy)), 0);
    }
}
