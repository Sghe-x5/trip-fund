pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TripFundCore} from "../src/TripFundCore.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TripToken} from "../src/TripToken.sol";

contract FailingToken is ERC20 {
    bool public failTransfer;
    bool public failTransferFrom;

    constructor() ERC20("Failing Token", "FAIL") {
        _mint(msg.sender, 10_000 ether);
    }

    function setFailures(bool transfer_, bool transferFrom_) external {
        failTransfer = transfer_;
        failTransferFrom = transferFrom_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, amount);
    }
}

contract ReentrantToken is ERC20 {
    address private _target;
    bytes private _payload;
    bytes4 public callbackError;

    constructor() ERC20("Reentrant Token", "REENTER") {
        _mint(msg.sender, 10_000 ether);
    }

    function arm(address target, bytes calldata payload) external {
        _target = target;
        _payload = payload;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _callback();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _callback();
        return super.transferFrom(from, to, amount);
    }

    function _callback() private {
        if (_target == address(0)) return;
        address target = _target;
        _target = address(0);
        (bool success, bytes memory result) = target.call(_payload);
        require(!success && result.length >= 4);
        callbackError = bytes4(result);
    }
}

abstract contract TripFundBehaviorTest is Test {
    TripToken internal token;
    TripFundCore internal fund;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal organizer = makeAddr("organizer");
    address internal owner = makeAddr("owner");
    uint256 internal end;
    uint256 internal constant GOAL = 100 ether;
    uint256 internal constant BALANCE = 1_000 ether;

    event Contributed(address indexed contributor, uint256 amount);
    event Refunded(address indexed contributor, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        virtual
        returns (TripFundCore);

    function setUp() public virtual {
        vm.warp(1_000_000);
        end = block.timestamp + 7 days;
        token = new TripToken(address(this), 10_000 ether);
        assertTrue(token.transfer(alice, BALANCE));
        assertTrue(token.transfer(bob, BALANCE));
        fund = _deploy(address(token), organizer, GOAL, end);
        vm.prank(alice);
        token.approve(address(fund), type(uint256).max);
        vm.prank(bob);
        token.approve(address(fund), type(uint256).max);
    }

    function _give(address participant, uint256 amount) internal {
        vm.prank(participant);
        fund.contribute(amount);
    }

    function testParameters() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(fund.organizer(), organizer);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), end);
        assertEq(fund.totalRaised(), 0);
        assertFalse(fund.withdrawn());
    }

    function testRejectsZeroToken() public {
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        _deploy(address(0), organizer, GOAL, end);
    }

    function testRejectsZeroOrganizer() public {
        vm.expectRevert(TripFundCore.ZeroAddress.selector);
        _deploy(address(token), address(0), GOAL, end);
    }

    function testRejectsZeroGoal() public {
        vm.expectRevert(TripFundCore.ZeroGoal.selector);
        _deploy(address(token), organizer, 0, end);
    }

    function testRejectsPresentDeadline() public {
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        _deploy(address(token), organizer, GOAL, block.timestamp);
    }

    function testRejectsPastDeadline() public {
        vm.expectRevert(TripFundCore.InvalidDeadline.selector);
        _deploy(address(token), organizer, GOAL, block.timestamp - 1);
    }

    function testTwoParticipantsAndRepeatedContributions() public {
        _give(alice, 10 ether);
        _give(bob, 20 ether);
        _give(alice, 30 ether);
        assertEq(fund.contributions(alice), 40 ether);
        assertEq(fund.contributions(bob), 20 ether);
        assertEq(fund.totalRaised(), 60 ether);
        assertEq(token.balanceOf(address(fund)), 60 ether);
        assertEq(token.balanceOf(alice), BALANCE - 40 ether);
        assertEq(token.balanceOf(bob), BALANCE - 20 ether);
    }

    function testContributionEvent() public {
        vm.expectEmit(true, false, false, true, address(fund));
        emit Contributed(alice, 10 ether);
        _give(alice, 10 ether);
    }

    function testZeroAmountRollsBack() public {
        vm.expectRevert(TripFundCore.ZeroAmount.selector);
        _give(alice, 0);
        _assertUnchanged();
    }

    function testInsufficientBalanceRollsBack() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, BALANCE, BALANCE + 1
            )
        );
        _give(alice, BALANCE + 1);
        _assertUnchanged();
        assertEq(token.allowance(alice, address(fund)), type(uint256).max);
    }

    function testInsufficientAllowanceRollsBack() public {
        vm.prank(alice);
        token.approve(address(fund), 9 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 9 ether, 10 ether
            )
        );
        _give(alice, 10 ether);
        _assertUnchanged();
        assertEq(token.allowance(alice, address(fund)), 9 ether);
    }

    function testContributionOneSecondBeforeDeadline() public {
        vm.warp(end - 1);
        _give(alice, 1 ether);
        assertEq(fund.totalRaised(), 1 ether);
    }

    function testContributionAtDeadlineRollsBack() public {
        vm.warp(end);
        vm.expectRevert(TripFundCore.FundingClosed.selector);
        _give(alice, 1 ether);
        _assertUnchanged();
    }

    function testContributionAfterDeadlineRollsBack() public {
        vm.warp(end + 1);
        vm.expectRevert(TripFundCore.FundingClosed.selector);
        _give(alice, 1 ether);
        _assertUnchanged();
    }

    function testNoEarlyWithdrawEvenAtGoal() public {
        _give(alice, GOAL);
        vm.warp(end - 1);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.FundingStillOpen.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL);
    }

    function testNoEarlyRefund() public {
        _give(alice, 10 ether);
        vm.warp(end - 1);
        vm.prank(alice);
        vm.expectRevert(TripFundCore.FundingStillOpen.selector);
        fund.refund();
        assertEq(fund.contributions(alice), 10 ether);
        assertEq(token.balanceOf(alice), BALANCE - 10 ether);
    }

    function testWithdrawExactGoalAtDeadline() public {
        _give(alice, GOAL);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Withdrawn(organizer, GOAL);
        vm.prank(organizer);
        fund.withdraw();
        _assertWithdrawn(GOAL);
    }

    function testWithdrawAboveGoal() public {
        _give(alice, 70 ether);
        _give(bob, 80 ether);
        vm.warp(end + 1);
        vm.prank(organizer);
        fund.withdraw();
        _assertWithdrawn(150 ether);
        assertEq(fund.contributions(alice), 70 ether);
        assertEq(fund.contributions(bob), 80 ether);
    }

    function testOnlyOrganizerCanWithdraw() public {
        _give(alice, GOAL);
        vm.warp(end);
        vm.prank(bob);
        vm.expectRevert(TripFundCore.OnlyOrganizer.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL);
    }

    function testCannotWithdrawTwice() public {
        _give(alice, GOAL);
        vm.warp(end);
        vm.startPrank(organizer);
        fund.withdraw();
        vm.expectRevert(TripFundCore.AlreadyWithdrawn.selector);
        fund.withdraw();
        vm.stopPrank();
        _assertWithdrawn(GOAL);
    }

    function testCannotWithdrawFailedFund() public {
        _give(alice, GOAL - 1);
        vm.warp(end);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.GoalNotReached.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(organizer), 0);
    }

    function testIndependentFullRefundsAtDeadline() public {
        _give(alice, 10 ether);
        _give(bob, 20 ether);
        _give(alice, 5 ether);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Refunded(bob, 20 ether);
        vm.prank(bob);
        fund.refund();
        assertEq(fund.contributions(alice), 15 ether);
        assertEq(fund.contributions(bob), 0);
        assertEq(token.balanceOf(address(fund)), 15 ether);
        assertEq(token.balanceOf(bob), BALANCE);
        vm.prank(alice);
        fund.refund();
        assertEq(fund.contributions(alice), 0);
        assertEq(token.balanceOf(alice), BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 35 ether);
    }

    function testCannotRefundWithoutContribution() public {
        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert(TripFundCore.NoContribution.selector);
        fund.refund();
    }

    function testCannotRefundTwice() public {
        _give(alice, 10 ether);
        vm.warp(end);
        vm.startPrank(alice);
        fund.refund();
        vm.expectRevert(TripFundCore.NoContribution.selector);
        fund.refund();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), BALANCE);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function testCannotRefundSuccessfulFundBeforeOrAfterWithdrawal() public {
        _give(alice, GOAL);
        vm.warp(end);
        vm.prank(alice);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        fund.refund();
        vm.prank(organizer);
        fund.withdraw();
        vm.prank(alice);
        vm.expectRevert(TripFundCore.GoalReached.selector);
        fund.refund();
    }

    function testDirectTransferRemainsAfterWithdrawal() public {
        assertTrue(token.transfer(address(fund), 7 ether));
        assertEq(fund.totalRaised(), 0);
        _give(alice, GOAL);
        vm.warp(end);
        vm.prank(organizer);
        fund.withdraw();
        assertEq(token.balanceOf(organizer), GOAL);
        assertEq(token.balanceOf(address(fund)), 7 ether);
        assertEq(fund.totalRaised(), GOAL);
    }

    function testDirectTransferDoesNotMakeFailedFundSuccessful() public {
        _give(alice, 10 ether);
        _give(bob, 20 ether);
        assertTrue(token.transfer(address(fund), GOAL));
        assertEq(fund.totalRaised(), 30 ether);
        vm.warp(end);
        vm.prank(organizer);
        vm.expectRevert(TripFundCore.GoalNotReached.selector);
        fund.withdraw();
        vm.prank(alice);
        fund.refund();
        vm.prank(bob);
        fund.refund();
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(alice), BALANCE);
        assertEq(token.balanceOf(bob), BALANCE);
        assertEq(fund.totalRaised(), 30 ether);
    }

    function testFalseTransferFromRollsBack() public {
        FailingToken bad = new FailingToken();
        TripFundCore other = _deploy(address(bad), organizer, GOAL, end);
        bad.approve(address(other), GOAL);
        bad.setFailures(false, true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        other.contribute(GOAL);
        assertEq(other.totalRaised(), 0);
        assertEq(other.contributions(address(this)), 0);
        assertEq(bad.balanceOf(address(other)), 0);
        assertEq(bad.balanceOf(address(this)), 10_000 ether);
        assertEq(bad.allowance(address(this), address(other)), GOAL);
    }

    function testWithdrawTransferFailureRestoresFlagAndCanRetry() public {
        FailingToken bad = new FailingToken();
        TripFundCore other = _deploy(address(bad), organizer, GOAL, end);
        bad.approve(address(other), GOAL);
        other.contribute(GOAL);
        bad.setFailures(true, false);
        vm.warp(end);
        vm.prank(organizer);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        other.withdraw();
        assertFalse(other.withdrawn());
        assertEq(other.totalRaised(), GOAL);
        assertEq(bad.balanceOf(address(other)), GOAL);
        assertEq(bad.balanceOf(organizer), 0);
        bad.setFailures(false, false);
        vm.prank(organizer);
        other.withdraw();
        assertTrue(other.withdrawn());
        assertEq(bad.balanceOf(organizer), GOAL);
    }

    function testRefundTransferFailureRestoresContributionAndCanRetry() public {
        FailingToken bad = new FailingToken();
        TripFundCore other = _deploy(address(bad), organizer, GOAL, end);
        bad.approve(address(other), 10 ether);
        other.contribute(10 ether);
        bad.setFailures(true, false);
        vm.warp(end);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        other.refund();
        assertEq(other.contributions(address(this)), 10 ether);
        assertEq(other.totalRaised(), 10 ether);
        assertEq(bad.balanceOf(address(other)), 10 ether);
        assertEq(bad.balanceOf(address(this)), 9_990 ether);
        bad.setFailures(false, false);
        other.refund();
        assertEq(other.contributions(address(this)), 0);
        assertEq(bad.balanceOf(address(this)), 10_000 ether);
    }

    function testReentrantContributionIsBlocked() public {
        ReentrantToken callbackToken = new ReentrantToken();
        TripFundCore other = _deploy(address(callbackToken), organizer, GOAL, end);
        callbackToken.approve(address(other), GOAL);
        callbackToken.arm(address(other), abi.encodeCall(TripFundCore.contribute, (1)));
        other.contribute(GOAL);
        assertEq(callbackToken.callbackError(), TripFundCore.ReentrantCall.selector);
        assertEq(other.contributions(address(this)), GOAL);
        assertEq(other.totalRaised(), GOAL);
        assertEq(callbackToken.balanceOf(address(other)), GOAL);
    }

    function testReentrantWithdrawalIsBlocked() public {
        ReentrantToken callbackToken = new ReentrantToken();
        TripFundCore other = _deploy(address(callbackToken), organizer, GOAL, end);
        callbackToken.approve(address(other), GOAL);
        other.contribute(GOAL);
        callbackToken.arm(address(other), abi.encodeCall(TripFundCore.withdraw, ()));
        vm.warp(end);
        vm.prank(organizer);
        other.withdraw();
        assertEq(callbackToken.callbackError(), TripFundCore.ReentrantCall.selector);
        assertTrue(other.withdrawn());
        assertEq(callbackToken.balanceOf(organizer), GOAL);
        assertEq(callbackToken.balanceOf(address(other)), 0);
    }

    function testReentrantRefundIsBlocked() public {
        ReentrantToken callbackToken = new ReentrantToken();
        TripFundCore other = _deploy(address(callbackToken), organizer, GOAL, end);
        callbackToken.approve(address(other), 1 ether);
        other.contribute(1 ether);
        callbackToken.arm(address(other), abi.encodeCall(TripFundCore.refund, ()));
        vm.warp(end);
        other.refund();
        assertEq(callbackToken.callbackError(), TripFundCore.ReentrantCall.selector);
        assertEq(other.contributions(address(this)), 0);
        assertEq(other.totalRaised(), 1 ether);
        assertEq(callbackToken.balanceOf(address(this)), 10_000 ether);
        assertEq(callbackToken.balanceOf(address(other)), 0);
    }

    function testFuzzContributionsAndSettlement(uint96 first, uint96 second) public {
        uint256 a = bound(uint256(first), 1, BALANCE);
        uint256 b = bound(uint256(second), 1, BALANCE);
        _give(alice, a);
        _give(bob, b);
        assertEq(fund.totalRaised(), a + b);
        vm.warp(end);
        if (a + b >= GOAL) {
            vm.prank(organizer);
            fund.withdraw();
            assertEq(token.balanceOf(organizer), a + b);
        } else {
            vm.prank(alice);
            fund.refund();
            vm.prank(bob);
            fund.refund();
            assertEq(token.balanceOf(alice), BALANCE);
            assertEq(token.balanceOf(bob), BALANCE);
        }
        assertEq(fund.totalRaised(), a + b);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function _assertUnchanged() internal view {
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(alice), 0);
        assertEq(fund.contributions(bob), 0);
        assertEq(token.balanceOf(alice), BALANCE);
        assertEq(token.balanceOf(bob), BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function _assertWithdrawn(uint256 amount) internal view {
        assertTrue(fund.withdrawn());
        assertEq(fund.totalRaised(), amount);
        assertEq(token.balanceOf(organizer), amount);
        assertEq(token.balanceOf(address(fund)), 0);
    }
}

contract TripFundTest is TripFundBehaviorTest {
    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        return new TripFund(token_, organizer_, goal_, deadline_);
    }
}

contract TripFundV1Test is TripFundBehaviorTest {
    TripFundV1 internal implementation;

    function setUp() public override {
        implementation = new TripFundV1();
        super.setUp();
    }

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        bytes memory data = abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_));
        return TripFundV1(address(new TransparentUpgradeableProxy(address(implementation), owner, data)));
    }
}

contract TripFundV2BehaviorTest is TripFundBehaviorTest {
    TripFundV2 internal implementation;

    function setUp() public override {
        implementation = new TripFundV2();
        super.setUp();
    }

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFundCore)
    {
        bytes memory data = abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_));
        return TripFundV2(address(new TransparentUpgradeableProxy(address(implementation), owner, data)));
    }
}
