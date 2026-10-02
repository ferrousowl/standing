// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StandingOrders, IERC20} from "../src/StandingOrders.sol";

/// @dev Runs against a fork of Arc mainnet so USDC is the real native-backed token.
///      ARC_RPC defaults to the public endpoint.
contract StandingOrdersTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;

    StandingOrders so;
    address owner = makeAddr("owner");
    address merchant = makeAddr("merchant");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint96 constant PRICE = 10e6; // 10 USDC
    uint32 constant MONTH = 30 days;
    uint96 constant TIP = 1000; // 0.001 USDC
    uint96 constant CAP = 50_000; // 0.05 USDC

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = EURC;
        so = new StandingOrders(owner, 30, tokens);
        // Native USDC has 18 decimals: 1000 ether of native balance is 1000 USDC.
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(keeper, 10 ether);
        vm.fee(20 gwei);
    }

    function _plan() internal returns (uint256 id) {
        vm.prank(merchant);
        id = so.createPlan(USDC, PRICE, MONTH, TIP, CAP, "Pro plan");
    }

    function _subscribe(address who, uint256 planId) internal returns (uint256 id) {
        if (who.balance == 0) vm.deal(who, 1000 ether);
        vm.startPrank(who);
        IERC20(USDC).approve(address(so), type(uint256).max);
        id = so.subscribe(planId, bytes32("ref-1"));
        vm.stopPrank();
    }

    // ── the native/ERC-20 duality the whole design rests on ──

    function test_nativeBalanceIsErc20Balance() public view {
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6);
        assertEq(alice.balance, 1000 ether);
    }

    // ── plans ──

    function test_createPlan_validates() public {
        vm.startPrank(merchant);
        vm.expectRevert(StandingOrders.TokenNotAllowed.selector);
        so.createPlan(address(0xdead), PRICE, MONTH, TIP, CAP, "x");
        vm.expectRevert(StandingOrders.BadParams.selector);
        so.createPlan(USDC, 0, MONTH, TIP, CAP, "x");
        vm.expectRevert(StandingOrders.BadParams.selector);
        so.createPlan(USDC, PRICE, 59 minutes, TIP, CAP, "x");
        vm.expectRevert(StandingOrders.BadParams.selector);
        so.createPlan(USDC, PRICE, MONTH, CAP + 1, CAP, "x"); // tip above cap
        vm.expectRevert(StandingOrders.BadParams.selector);
        so.createPlan(USDC, PRICE, MONTH, TIP, PRICE / 2 + 1, "x"); // cap above half the price
        vm.stopPrank();
    }

    // ── subscribing ──

    function test_subscribe_paysFirstPeriod() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);

        uint256 fee = uint256(PRICE) * 30 / 10_000;
        assertEq(IERC20(USDC).balanceOf(merchant), PRICE - fee, "merchant gets price minus protocol fee");
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6 - PRICE, "payer pays exactly the price");
        assertEq(so.accruedFees(USDC), fee);
        assertEq(IERC20(USDC).balanceOf(address(so)), fee, "contract holds only accrued fees");

        StandingOrders.Order memory o = so.getOrder(orderId);
        assertEq(o.nextDue, block.timestamp + MONTH);
        assertEq(o.payments, 1);
        assertTrue(so.isCurrent(planId, alice, 0));
        assertFalse(so.isCurrent(planId, bob, 0));
    }

    function test_subscribe_twiceReverts() public {
        uint256 planId = _plan();
        _subscribe(alice, planId);
        vm.prank(alice);
        vm.expectRevert(StandingOrders.AlreadySubscribed.selector);
        so.subscribe(planId, 0);
    }

    function test_subscribe_withoutAllowanceReverts() public {
        uint256 planId = _plan();
        vm.prank(alice);
        vm.expectRevert(StandingOrders.PullFailed.selector);
        so.subscribe(planId, 0);
    }

    // ── execution ──

    function test_execute_notDueReverts() public {
        uint256 orderId = _subscribe(alice, _plan());
        vm.warp(block.timestamp + MONTH - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotDue.selector, uint40(block.timestamp + 1)));
        so.execute(orderId);
    }

    function test_execute_refundsKeeperGasInUsdc() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        vm.warp(block.timestamp + MONTH);

        uint256 merchantBefore = IERC20(USDC).balanceOf(merchant);
        uint256 keeperBefore = IERC20(USDC).balanceOf(keeper);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(keeper);
        uint256 g = gasleft();
        so.execute(orderId);
        uint256 callGas = g - gasleft();

        uint256 execFee = IERC20(USDC).balanceOf(keeper) - keeperBefore;
        uint256 protocolFee = uint256(PRICE) * 30 / 10_000;
        assertEq(aliceBefore - IERC20(USDC).balanceOf(alice), PRICE, "payer pays exactly the price");
        assertEq(IERC20(USDC).balanceOf(merchant) - merchantBefore, PRICE - protocolFee - execFee);

        // The refund must cover what the keeper really spends (call gas + 21000 intrinsic + calldata)
        // at the base fee, and stay within 25% of it: a refund, not a windfall.
        uint256 realCost = (callGas + 21_000 + 600) * block.basefee / 1e12;
        assertGe(execFee, realCost + TIP, "keeper is made whole");
        assertLe(execFee, realCost * 125 / 100 + TIP + 1, "refund is tight");
        emit log_named_uint("call gas", callGas);
        emit log_named_uint("exec fee (micro-USDC)", execFee);
    }

    function test_execute_refundIgnoresTxGasPrice() public {
        uint256 planId = _plan();
        uint256 warmup = _subscribe(makeAddr("carol-funded"), planId);
        uint256 orderId = _subscribe(alice, planId);
        uint256 orderId2 = _subscribe(bob, planId);
        vm.warp(block.timestamp + MONTH);
        // A test runs as one transaction: settle one order first so the once-per-transaction
        // overhead is out of the way and the two measured payments are like for like.
        vm.prank(keeper);
        so.execute(warmup);

        uint256 k = IERC20(USDC).balanceOf(keeper);
        vm.txGasPrice(20 gwei);
        vm.prank(keeper);
        so.execute(orderId);
        uint256 feeLow = IERC20(USDC).balanceOf(keeper) - k;

        k = IERC20(USDC).balanceOf(keeper);
        vm.txGasPrice(5000 gwei);
        vm.prank(keeper);
        so.execute(orderId2);
        uint256 feeHigh = IERC20(USDC).balanceOf(keeper) - k;
        assertApproxEqAbs(feeHigh, feeLow, 100, "overbidding does not raise the refund");
    }

    function test_execute_feeCappedWhenBaseFeeSpikes() public {
        uint256 orderId = _subscribe(alice, _plan());
        vm.warp(block.timestamp + MONTH);
        vm.fee(20_000 gwei); // Arc's maximum base fee
        uint256 k = IERC20(USDC).balanceOf(keeper);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(IERC20(USDC).balanceOf(keeper) - k, CAP, "merchant never pays above the cap");
    }

    function test_execute_latePaymentsDoNotStack() public {
        uint256 orderId = _subscribe(alice, _plan());
        vm.warp(block.timestamp + 3 * uint256(MONTH) + 5 days);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(so.getOrder(orderId).nextDue, block.timestamp + MONTH, "schedule restarts from now");
        vm.prank(keeper);
        vm.expectRevert();
        so.execute(orderId);
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6 - 2 * uint256(PRICE), "charged once for the gap");
    }

    function test_execute_slightlyLateKeepsBillingDate() public {
        uint256 orderId = _subscribe(alice, _plan());
        uint256 due = so.getOrder(orderId).nextDue;
        vm.warp(due + 3 days); // at the tolerance: min(period / 4, 3 days)
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(so.getOrder(orderId).nextDue, due + MONTH, "billing date does not drift");
    }

    function test_execute_lateBeyondToleranceRestartsSchedule() public {
        uint256 orderId = _subscribe(alice, _plan());
        uint256 due = so.getOrder(orderId).nextDue;
        vm.warp(due + 3 days + 1);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(so.getOrder(orderId).nextDue, block.timestamp + MONTH, "a late payment buys a full period");
    }

    function test_execute_shortPeriodToleranceIsAQuarter() public {
        vm.prank(merchant);
        uint256 planId = so.createPlan(USDC, PRICE, 4 hours, TIP, CAP, "4h");
        uint256 orderId = _subscribe(alice, planId);
        uint256 due = so.getOrder(orderId).nextDue;
        vm.warp(due + 1 hours + 1);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(so.getOrder(orderId).nextDue, block.timestamp + 4 hours);
    }

    function test_execute_payerCannotPayReverts() public {
        uint256 orderId = _subscribe(alice, _plan());
        vm.prank(alice);
        IERC20(USDC).approve(address(so), 0);
        vm.warp(block.timestamp + MONTH);
        vm.prank(keeper);
        vm.expectRevert(StandingOrders.PullFailed.selector);
        so.execute(orderId);
        assertEq(so.getOrder(orderId).payments, 1, "failed payment leaves the order untouched");
    }

    function test_executeBatch_skipsBadOrders() public {
        uint256 planId = _plan();
        uint256 a = _subscribe(alice, planId);
        uint256 b = _subscribe(bob, planId);
        vm.prank(bob);
        IERC20(USDC).approve(address(so), 0); // bob can no longer pay
        vm.warp(block.timestamp + MONTH);

        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (a, b, 999, a); // good, unpayable, nonexistent, duplicate
        uint256 k = IERC20(USDC).balanceOf(keeper);
        vm.prank(keeper);
        uint256 paid = so.executeBatch(ids);
        assertEq(paid, 1);
        assertEq(so.getOrder(a).payments, 2);
        assertEq(so.getOrder(b).payments, 1);
        assertGt(IERC20(USDC).balanceOf(keeper), k);
    }

    function test_executeFor_onlySelf() public {
        uint256 orderId = _subscribe(alice, _plan());
        vm.warp(block.timestamp + MONTH);
        vm.prank(keeper);
        vm.expectRevert(StandingOrders.NotAuthorized.selector);
        so.executeFor(orderId, keeper);
    }

    function test_executable_listsOnlyPayableDueOrders() public {
        uint256 planId = _plan();
        uint256 a = _subscribe(alice, planId);
        _subscribe(bob, planId);
        assertEq(so.executable(0, 100, 0).length, 0, "nothing due yet");
        vm.prank(bob);
        IERC20(USDC).approve(address(so), 0);
        vm.warp(block.timestamp + MONTH);
        uint256[] memory ids = so.executable(0, 100, 0);
        assertEq(ids.length, 1);
        assertEq(ids[0], a);
    }

    // ── leaving ──

    function test_cancel_byPayerStopsPayments() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        vm.prank(bob);
        vm.expectRevert(StandingOrders.NotAuthorized.selector);
        so.cancel(orderId);
        vm.prank(alice);
        so.cancel(orderId);
        assertTrue(so.isCurrent(planId, alice, 0), "the period already paid for is kept");
        vm.warp(block.timestamp + MONTH);
        assertFalse(so.isCurrent(planId, alice, 3 days), "no grace once cancelled");
        vm.prank(keeper);
        vm.expectRevert(StandingOrders.OrderInactive.selector);
        so.execute(orderId);
        // and the payer may come back later, paying for a fresh period
        vm.prank(alice);
        so.subscribe(planId, 0);
        assertTrue(so.isCurrent(planId, alice, 0));
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6 - 2 * uint256(PRICE));
    }

    function test_resubscribe_withinPaidTimeIsFree() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        uint256 paidThrough = so.getOrder(orderId).nextDue;
        vm.prank(merchant);
        so.cancel(orderId);
        vm.warp(block.timestamp + 10 days);

        vm.prank(alice);
        uint256 again = so.subscribe(planId, 0);
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6 - PRICE, "not charged twice for the same month");
        assertEq(so.getOrder(again).nextDue, paidThrough, "next payment when the paid time ends");
        assertEq(so.getOrder(again).payments, 0);
        (bool live, uint256 id) = so.liveOrderOf(planId, alice);
        assertTrue(live);
        assertEq(id, again);

        vm.warp(paidThrough);
        vm.prank(keeper);
        so.execute(again);
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6 - 2 * uint256(PRICE));
    }

    function test_closePlan_stopsEverything() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        vm.prank(alice);
        vm.expectRevert(StandingOrders.NotAuthorized.selector);
        so.closePlan(planId);
        vm.prank(merchant);
        so.closePlan(planId);
        assertTrue(so.isCurrent(planId, alice, 0), "closing a plan does not take back paid time");
        vm.warp(block.timestamp + MONTH);
        assertFalse(so.isCurrent(planId, alice, 3 days));
        vm.prank(keeper);
        vm.expectRevert(StandingOrders.PlanInactive.selector);
        so.execute(orderId);
        vm.prank(bob);
        vm.expectRevert(StandingOrders.PlanInactive.selector);
        so.subscribe(planId, 0);
    }

    function test_isCurrent_respectsGrace() public {
        uint256 planId = _plan();
        _subscribe(alice, planId);
        vm.warp(block.timestamp + MONTH + 1 days);
        assertFalse(so.isCurrent(planId, alice, 0));
        assertTrue(so.isCurrent(planId, alice, 3 days));
    }

    // ── EURC: no gas refund, flat tip only ──

    function test_eurcPlan_paysFlatTip() public {
        deal(EURC, alice, 100e6);
        vm.prank(merchant);
        uint256 planId = so.createPlan(EURC, 5e6, 7 days, 2000, 10_000, "Weekly EUR");
        vm.startPrank(alice);
        IERC20(EURC).approve(address(so), type(uint256).max);
        uint256 orderId = so.subscribe(planId, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(IERC20(EURC).balanceOf(keeper), 2000);
        assertEq(IERC20(EURC).balanceOf(merchant), 2 * (5e6 - 15_000) - 2000);
    }

    // ── admin ──

    function test_admin() public {
        _subscribe(alice, _plan());
        vm.expectRevert(StandingOrders.NotOwner.selector);
        so.withdrawFees(USDC, address(this));
        vm.startPrank(owner);
        vm.expectRevert(StandingOrders.BadParams.selector);
        so.setFeeBps(101);
        so.setFeeBps(0);
        address treasury = makeAddr("treasury");
        so.withdrawFees(USDC, treasury);
        assertEq(IERC20(USDC).balanceOf(treasury), 30_000);
        assertEq(IERC20(USDC).balanceOf(address(so)), 0);
        so.transferOwnership(bob);
        vm.stopPrank();
        assertEq(so.owner(), owner, "two-step: unchanged until accepted");
        vm.prank(bob);
        so.acceptOwnership();
        assertEq(so.owner(), bob);
    }

    /// @dev Whatever the price, fee and base fee: the payer pays exactly `amount`, and the three
    ///      recipients receive exactly `amount` between them.
    function testFuzz_conservation(uint96 amount, uint16 feeBps, uint64 baseFee) public {
        amount = uint96(bound(amount, 1000, 500e6));
        feeBps = uint16(bound(feeBps, 0, 100));
        baseFee = uint64(bound(baseFee, 20 gwei, 20_000 gwei));
        vm.prank(owner);
        so.setFeeBps(feeBps);
        uint96 cap = amount / 2;
        vm.prank(merchant);
        uint256 planId = so.createPlan(USDC, amount, 1 days, cap / 10, cap, "f");
        uint256 orderId = _subscribe(alice, planId);
        vm.warp(block.timestamp + 1 days);
        vm.fee(baseFee);
        vm.prank(keeper);
        so.execute(orderId);

        uint256 k = IERC20(USDC).balanceOf(keeper) - 10e6;
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6 - 2 * uint256(amount));
        assertEq(IERC20(USDC).balanceOf(merchant) + k + so.accruedFees(USDC), 2 * uint256(amount));
        assertEq(IERC20(USDC).balanceOf(address(so)), so.accruedFees(USDC));
        assertLe(k, cap);
    }
}
