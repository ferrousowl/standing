// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Proof-of-concept tests from an adversarial review of StandingOrders. F1–F4 were real findings;
// each is fixed in the contract and its test now asserts the corrected behaviour. The `sound`
// tests record properties the review probed and found to hold.

import {Test, Vm} from "forge-std/Test.sol";
import {StandingOrders, IERC20} from "../src/StandingOrders.sol";

/// @dev Executor contract that loops single execute() calls inside one transaction.
contract Looper {
    function run(StandingOrders so, uint256[] calldata ids) external {
        for (uint256 i; i < ids.length; ++i) {
            so.execute(ids[i]);
        }
    }
}

struct Call3 {
    address target;
    bool allowFailure;
    bytes callData;
}

struct Result {
    bool success;
    bytes returnData;
}

interface IMulticall3From {
    function aggregate3(Call3[] calldata calls) external returns (Result[] memory);
}

/// @dev Recipient whose code always reverts and burns gas if it is ever entered.
contract HostileRecipient {
    fallback() external payable {
        for (uint256 i; i < 1e9; ++i) {}
        revert("entered");
    }

    receive() external payable {
        for (uint256 i; i < 1e9; ++i) {}
        revert("entered");
    }
}

/// @dev Adversarial review PoCs. Forks Arc mainnet like the main suite.
contract ReviewTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;

    StandingOrders so;
    address owner = makeAddr("owner");
    address merchant = makeAddr("merchant");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    uint96 constant PRICE = 10e6;
    uint32 constant MONTH = 30 days;
    uint96 constant TIP = 1000;
    uint96 constant CAP = 50_000;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://rpc.mainnet.arc.io")));
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = EURC;
        so = new StandingOrders(owner, 30, tokens);
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
        vm.startPrank(who);
        IERC20(USDC).approve(address(so), type(uint256).max);
        id = so.subscribe(planId, bytes32("ref-1"));
        vm.stopPrank();
    }

    function _payers(uint256 n, uint256 planId) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address p = address(uint160(0xA11CE000 + i));
            vm.deal(p, 100 ether);
            ids[i] = _subscribe(p, planId);
        }
    }

    /// @dev arc-forge returns the 5-field Gas struct; decode it by hand.
    function _lastGas() internal view returns (uint256 used) {
        (, bytes memory ret) = address(vm).staticcall(abi.encodeWithSignature("lastCallGas()"));
        (, uint64 u,,,) = abi.decode(ret, (uint64, uint64, uint64, int64, uint64));
        used = u;
    }

    // ── F1 (fixed): a payment collected late used to keep the old billing date, so a payer could
    //        be charged twice back to back. Beyond a tolerance the schedule now restarts. ──

    function test_F1_latePaymentNoLongerStacks() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        uint256 due = so.getOrder(orderId).nextDue;

        // Alice cannot be charged for most of the second month (allowance revoked / empty wallet).
        vm.prank(alice);
        IERC20(USDC).approve(address(so), 0);
        vm.warp(due + MONTH - 1); // one second before a full period of lateness
        assertFalse(so.isCurrent(planId, alice, 3 days), "merchant already treats her as unpaid");
        vm.prank(alice);
        IERC20(USDC).approve(address(so), type(uint256).max);

        uint256 balBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(so.getOrder(orderId).nextDue, block.timestamp + MONTH, "the payment buys a full month");

        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        vm.expectRevert();
        so.execute(orderId);
        assertEq(balBefore - IERC20(USDC).balanceOf(alice), PRICE, "charged once");
    }

    /// @dev Control: one second later the same payer is charged once. The extra charge above is
    ///      purely a function of *when* the keeper lands, not of what the payer owes.
    function test_F1_control_oneSecondLaterChargesOnce() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        uint256 due = so.getOrder(orderId).nextDue;
        vm.warp(due + MONTH);
        uint256 balBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(so.getOrder(orderId).nextDue, block.timestamp + MONTH);
        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        vm.expectRevert();
        so.execute(orderId);
        assertEq(balBefore - IERC20(USDC).balanceOf(alice), PRICE);
    }

    // ── F2 (fixed): cancelling or closing the plan used to forfeit the period already paid. ──

    function test_F2_merchantCancelRightAfterChargeKeepsPaidPeriod() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        vm.prank(merchant);
        so.cancel(orderId); // same block as the charge
        assertTrue(so.isCurrent(planId, alice, 0), "paid, so current");

        vm.prank(alice);
        so.subscribe(planId, 0);
        assertEq(IERC20(USDC).balanceOf(alice), 1000e6 - PRICE, "coming back in the same month is free");
    }

    function test_F2_closePlanRightAfterRenewalKeepsPaidPeriod() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        vm.warp(block.timestamp + MONTH);
        vm.prank(keeper);
        so.execute(orderId); // alice pays month two
        vm.prank(merchant);
        so.closePlan(planId);
        assertTrue(so.isCurrent(planId, alice, 0));
        vm.warp(block.timestamp + MONTH);
        assertFalse(so.isCurrent(planId, alice, 30 days), "and no further, grace or not");
    }

    // ── F3 (fixed): the per-transaction overhead (21k intrinsic gas and first-touch costs) used
    //        to be refunded per execute() call, so a keeper looping execute() in one transaction
    //        collected it N times. It is now refunded once per transaction. ──

    /// @dev Real transaction gas of the looped runs below, measured with `--isolate`.
    uint256 constant LOOP_TX_GAS_ISOLATED = 1_567_735;
    uint256 constant MULTICALL_TX_GAS_ISOLATED = 1_646_111;

    function test_F3_loopedExecute_refundTracksCost() public {
        uint256 n = 20;
        uint256[] memory ids = _payers(n, _plan());
        vm.warp(block.timestamp + MONTH);
        Looper looper = new Looper();
        vm.prank(keeper);
        looper.run(so, ids);
        // Everything is warm in this test context, so the measured part is at its minimum; on a
        // fork with real transactions the refund came to 101% of cost for this route.
        uint256 refundGasEq = (IERC20(USDC).balanceOf(address(looper)) - n * TIP) * 1e12 / 20 gwei;
        emit log_named_uint("gas refunded by merchants for 20 orders (lower bound)", refundGasEq);
        if (refundGasEq == 0) return; // --isolate zeroes block.basefee: nothing to compare
        assertLt(refundGasEq, LOOP_TX_GAS_ISOLATED, "looping no longer over-refunds");
        assertGt(refundGasEq * 100, LOOP_TX_GAS_ISOLATED * 70, "and still roughly covers the keeper");
    }

    /// @dev Run with --isolate: lastCallGas is then the whole transaction incl. intrinsic gas.
    function test_F3_loopedExecute_txGas() public {
        uint256 n = 20;
        uint256[] memory ids = _payers(n, _plan());
        vm.warp(block.timestamp + MONTH);
        Looper looper = new Looper();
        vm.prank(keeper);
        looper.run(so, ids);
        uint256 txGas = _lastGas();
        emit log_named_uint("tx gas for 20 orders", txGas);
        assertLe(txGas, LOOP_TX_GAS_ISOLATED);
    }

    /// @dev No contract needed: Arc's predeployed Multicall3From keeps the EOA as msg.sender.
    function test_F3_multicall3FromLoop_refundTracksCost() public {
        uint256 n = 20;
        uint256[] memory ids = _payers(n, _plan());
        vm.warp(block.timestamp + MONTH);
        Call3[] memory calls = new Call3[](n);
        for (uint256 i; i < n; ++i) {
            calls[i] = Call3(address(so), false, abi.encodeCall(StandingOrders.execute, (ids[i])));
        }
        uint256 k = IERC20(USDC).balanceOf(keeper);
        vm.prank(keeper, keeper);
        IMulticall3From(0x522fAf9A91c41c443c66765030741e4AaCe147D0).aggregate3(calls);
        uint256 refundGasEq = (IERC20(USDC).balanceOf(keeper) - k - n * TIP) * 1e12 / 20 gwei;
        emit log_named_uint("multicall tx gas for 20 orders", _lastGas());
        emit log_named_uint("multicall gas refunded (lower bound)", refundGasEq);
        assertEq(so.getOrder(ids[n - 1]).payments, 2);
        if (refundGasEq == 0) return; // --isolate zeroes block.basefee
        assertLt(refundGasEq, MULTICALL_TX_GAS_ISOLATED, "looping no longer over-refunds");
    }

    /// @dev A gas estimate must not be able to settle on a limit that silently starves an order.
    function test_batchRevertsRatherThanStarveAnOrder() public {
        uint256[] memory ids = _payers(2, _plan());
        vm.warp(block.timestamp + MONTH);
        vm.prank(keeper);
        (bool ok, bytes memory ret) =
            address(so).call{gas: 150_000}(abi.encodeCall(StandingOrders.executeBatch, (ids)));
        assertFalse(ok);
        assertEq(bytes4(ret), StandingOrders.InsufficientGas.selector);
    }

    // ── F4 (fixed): executable() used to list dust orders that pay the keeper nothing. ──

    function test_F4_dustPlansAreFilteredByMinExecFee() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        vm.startPrank(attacker);
        IERC20(USDC).approve(address(so), type(uint256).max);
        for (uint256 i; i < 10; ++i) {
            // 1 micro-USDC per hour, paid to self; zero tip, zero cap.
            uint256 planId = so.createPlan(USDC, 1, 1 hours, 0, 0, "dust");
            so.subscribe(planId, 0);
        }
        vm.stopPrank();
        uint256 good = _subscribe(alice, _plan());
        vm.warp(block.timestamp + MONTH);

        assertEq(so.executable(0, 100, 0).length, 11, "unfiltered view lists everything due");
        uint256[] memory ids = so.executable(0, 100, 2000); // a keeper asking for its gas back
        assertEq(ids.length, 1, "dust is not worth executing");
        assertEq(ids[0], good);
    }

    /// @dev One allowance backs many orders: executable() lists them all, only one can pay.
    function test_F4_executableOverReportsSharedAllowance() public {
        uint256 n = 5;
        uint256[] memory ids = new uint256[](n);
        vm.startPrank(merchant);
        for (uint256 i; i < n; ++i) {
            so.createPlan(USDC, PRICE, 1 hours, TIP, CAP, "p");
        }
        vm.stopPrank();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(so), type(uint256).max);
        for (uint256 i; i < n; ++i) {
            ids[i] = so.subscribe(i, 0);
        }
        IERC20(USDC).approve(address(so), PRICE); // enough for exactly one
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours);
        assertEq(so.executable(0, 100, 0).length, n);
        vm.prank(keeper);
        assertEq(so.executeBatch(ids), 1);
    }

    // ── checks that came out sound ──

    /// @dev ERC-20 USDC transfers go through the native-coin precompile and never enter the
    ///      recipient's code, so a 7702-delegated or contract merchant cannot burn measured gas
    ///      or block/reenter a payment.
    function test_sound_recipientCodeIsNotRun() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        vm.warp(block.timestamp + MONTH);

        uint256 snap = vm.snapshotState();
        uint256 k = IERC20(USDC).balanceOf(keeper);
        vm.prank(keeper);
        so.execute(orderId);
        uint256 feePlain = IERC20(USDC).balanceOf(keeper) - k;
        vm.revertToState(snap);

        HostileRecipient h = new HostileRecipient();
        vm.etch(merchant, address(h).code);
        vm.etch(alice, address(h).code);
        vm.etch(keeper, address(h).code);
        uint256 m = IERC20(USDC).balanceOf(merchant);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(IERC20(USDC).balanceOf(keeper) - k, feePlain, "same refund: no extra gas measured");
        assertGt(IERC20(USDC).balanceOf(merchant), m);
    }

    /// @dev Force-fed native USDC (including sub-micro dust that balanceOf truncates) neither
    ///      breaks the balance-delta check nor becomes withdrawable; it is simply stranded.
    function test_sound_forceSentDustDoesNotBreakPull() public {
        uint256 planId = _plan();
        uint256 orderId = _subscribe(alice, planId);
        vm.deal(address(so), address(so).balance + 5 ether + 999_999_999_999); // 5 USDC + dust
        vm.warp(block.timestamp + MONTH);
        vm.prank(keeper);
        so.execute(orderId);
        assertEq(so.accruedFees(USDC), 60_000);
        vm.prank(owner);
        so.withdrawFees(USDC, owner);
        assertEq(IERC20(USDC).balanceOf(owner), 60_000);
        assertEq(IERC20(USDC).balanceOf(address(so)), 5e6, "donation is stuck: there is no sweep");
    }

    /// @dev Worst-case rounding: 1% protocol fee and cap = amount / 2 never underflow `net`.
    function testFuzz_sound_netNeverUnderflows(uint96 amount) public {
        amount = uint96(bound(amount, 1, 450e6)); // alice holds 1000 USDC and pays twice
        vm.prank(owner);
        so.setFeeBps(100);
        vm.prank(merchant);
        uint256 planId = so.createPlan(USDC, amount, 1 hours, amount / 2, amount / 2, "f");
        uint256 orderId = _subscribe(alice, planId);
        vm.warp(block.timestamp + 1 hours);
        vm.fee(20_000 gwei);
        uint256 m = IERC20(USDC).balanceOf(merchant);
        vm.prank(keeper);
        so.execute(orderId);
        assertGt(IERC20(USDC).balanceOf(merchant), m, "merchant always nets something");
        assertEq(IERC20(USDC).balanceOf(address(so)), so.accruedFees(USDC));
    }

    /// @dev A blocklisted merchant makes every order on the plan unexecutable, but only that plan:
    ///      the payer is not charged and a batch carries on. executable() still lists the order.
    function test_sound_blocklistedMerchantOnlySkips() public {
        uint256 planId = _plan();
        uint256 a = _subscribe(alice, planId);
        vm.prank(bob); // a second, healthy plan
        uint256 plan2 = so.createPlan(USDC, PRICE, MONTH, TIP, CAP, "ok");
        uint256 b = _subscribe(bob, plan2);
        vm.warp(block.timestamp + MONTH);

        (, bytes memory ret) = USDC.staticcall(abi.encodeWithSignature("blacklister()"));
        address blacklister = abi.decode(ret, (address));
        vm.prank(blacklister);
        (bool ok,) = USDC.call(abi.encodeWithSignature("blacklist(address)", merchant));
        assertTrue(ok, "could not blocklist in the emulator");

        uint256 aliceBal = IERC20(USDC).balanceOf(alice);
        vm.prank(keeper);
        vm.expectRevert();
        so.execute(a);

        assertEq(so.executable(0, 100, 0).length, 2, "view still advertises the dead order");
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (a, b);
        vm.prank(keeper);
        assertEq(so.executeBatch(ids), 1);
        assertEq(IERC20(USDC).balanceOf(alice), aliceBal, "payer of the blocked plan not charged");
    }

    /// @dev 63/64 rule: starving executeBatch of gas only ever skips whole orders. For every gas
    ///      limit tried, each order is either fully paid or untouched, the executor is paid only
    ///      for orders that paid, and the contract holds exactly its accrued fees.
    function test_sound_batchGasStarvationIsAtomic() public {
        uint256 n = 4;
        uint256[] memory ids = _payers(n, _plan());
        vm.warp(block.timestamp + MONTH);
        uint256 k = IERC20(USDC).balanceOf(keeper);
        for (uint256 gasLimit = 30_000; gasLimit < 420_000; gasLimit += 3_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok, bytes memory ret) =
                address(so).call{gas: gasLimit}(abi.encodeCall(StandingOrders.executeBatch, (ids)));
            uint256 paid;
            for (uint256 i; i < n; ++i) {
                paid += so.getOrder(ids[i]).payments - 1;
            }
            if (ok) assertEq(abi.decode(ret, (uint256)), paid);
            else assertEq(paid, 0);
            uint256 earned = IERC20(USDC).balanceOf(keeper) - k;
            assertLe(earned, paid * CAP);
            assertEq(earned == 0, paid == 0);
            assertEq(IERC20(USDC).balanceOf(address(so)), so.accruedFees(USDC));
            assertEq(so.accruedFees(USDC), (n + paid) * 30_000);
            vm.revertToState(snap);
        }
    }
}
