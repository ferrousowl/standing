// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title StandingOrders — recurring stablecoin payments for Arc
/// @notice A merchant publishes a plan (token, amount, period). A payer subscribes once and
///         approves an allowance. From then on *anyone* may execute a payment once it is due.
///
///         The executor is refunded the gas it spent, out of the payment itself. This is exact
///         on Arc because gas is paid in USDC: `gasUsed * block.basefee` is already a USDC
///         amount (18 decimals), so it converts to the ERC-20 interface (6 decimals) by a
///         fixed factor of 1e12 — no price oracle, no keeper token, no off-chain agreement.
///
///         The contract never custodies payer funds: every payment is pulled and paid out in
///         the same transaction. Only accrued protocol fees rest here until withdrawn.
contract StandingOrders {
    // ───────────────────────────── types ─────────────────────────────

    struct Plan {
        address merchant;
        address token;
        uint96 amount; // charged to the payer every period, in token units
        uint32 period; // seconds between payments
        uint96 keeperTip; // flat incentive paid to the executor on top of the gas refund
        uint96 maxExecFee; // hard cap on (gas refund + tip) the merchant will ever pay per payment
        bool active;
        string name;
    }

    struct Order {
        uint64 planId;
        address payer;
        uint40 nextDue;
        uint40 startedAt;
        uint32 payments;
        bool active;
    }

    // ─────────────────────────── constants ───────────────────────────

    /// @dev Arc's ERC-20 view of the native gas token. 6 decimals; the native view has 18.
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant NATIVE_TO_ERC20 = 1e12;

    uint16 public constant MAX_FEE_BPS = 100; // protocol fee can never exceed 1%
    uint32 public constant MIN_PERIOD = 1 hours;

    /// @dev Gas the in-call measurement cannot see, calibrated against real transactions on a
    ///      mainnet fork. ORDER_OVERHEAD covers the payout transfers and event that run after the
    ///      measurement is taken. TX_OVERHEAD covers the 21000 intrinsic gas, calldata and the
    ///      first-touch cost of those payouts; it is refunded once per transaction however many
    ///      orders the transaction settles.
    uint256 internal constant ORDER_OVERHEAD = 39_000;
    uint256 internal constant TX_OVERHEAD = 29_500;

    /// @dev Gas that must remain before a batched order is attempted. Without it, a gas estimate
    ///      could settle on a limit that starves an order, which the batch would then skip silently.
    uint256 internal constant MIN_GAS_PER_ORDER = 250_000;

    /// @dev Gas a typical settlement costs; used only to rank orders in `executable`.
    uint256 internal constant TYPICAL_EXEC_GAS = 110_000;

    /// @dev A payment collected this late or later restarts the schedule instead of keeping it.
    uint256 internal constant MAX_LATE_TOLERANCE = 3 days;

    // ──────────────────────────── storage ────────────────────────────

    address public owner;
    address public pendingOwner;
    uint16 public feeBps;

    Plan[] internal _plans;
    Order[] internal _orders;

    mapping(address token => bool) public tokenAllowed;
    mapping(address token => uint256) public accruedFees;
    mapping(address merchant => uint256[]) internal _plansOf;
    mapping(address payer => uint256[]) internal _ordersOf;
    mapping(uint256 planId => uint256[]) internal _ordersOfPlan;
    /// @dev orderId + 1 of the payer's live order on a plan; 0 when there is none.
    mapping(uint256 planId => mapping(address payer => uint256)) internal _liveOrder;
    /// @notice Time a payer has paid through on a plan. Outlives cancellation and plan closure:
    ///         what was paid for stays paid for.
    mapping(uint256 planId => mapping(address payer => uint40)) public paidUntil;

    bool private transient _locked;
    bool private transient _txOverheadRefunded;

    // ──────────────────────────── events ─────────────────────────────

    event PlanCreated(
        uint256 indexed planId, address indexed merchant, address indexed token, uint256 amount, uint32 period, string name
    );
    event PlanClosed(uint256 indexed planId);
    event Subscribed(uint256 indexed orderId, uint256 indexed planId, address indexed payer, bytes32 ref);
    event Cancelled(uint256 indexed orderId, address indexed by);
    event Paid(
        uint256 indexed orderId,
        uint256 indexed planId,
        address indexed executor,
        uint256 amount,
        uint256 merchantNet,
        uint256 protocolFee,
        uint256 execFee,
        uint40 nextDue
    );
    event TokenAllowed(address indexed token, bool allowed);
    event FeeChanged(uint16 feeBps);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ──────────────────────────── errors ─────────────────────────────

    error NotOwner();
    error NotAuthorized();
    error BadParams();
    error TokenNotAllowed();
    error PlanInactive();
    error OrderInactive();
    error AlreadySubscribed();
    error NotDue(uint40 nextDue);
    error PullFailed();
    error TransferFailed();
    error Reentrancy();
    error InsufficientGas();

    // ─────────────────────────── modifiers ───────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address owner_, uint16 feeBps_, address[] memory tokens) {
        if (owner_ == address(0) || feeBps_ > MAX_FEE_BPS) revert BadParams();
        owner = owner_;
        feeBps = feeBps_;
        emit OwnershipTransferred(address(0), owner_);
        emit FeeChanged(feeBps_);
        for (uint256 i; i < tokens.length; ++i) {
            tokenAllowed[tokens[i]] = true;
            emit TokenAllowed(tokens[i], true);
        }
    }

    // ─────────────────────────── merchants ───────────────────────────

    /// @notice Publish a plan. Terms are immutable: payers can rely on never being charged more.
    /// @param keeperTip  flat executor incentive per payment, in token units
    /// @param maxExecFee cap on what an executor can take from one payment (gas refund + tip)
    function createPlan(
        address token,
        uint96 amount,
        uint32 period,
        uint96 keeperTip,
        uint96 maxExecFee,
        string calldata name
    ) external returns (uint256 planId) {
        if (!tokenAllowed[token]) revert TokenNotAllowed();
        if (amount == 0 || period < MIN_PERIOD || bytes(name).length > 64) revert BadParams();
        // The executor's share must always leave something for the merchant.
        if (keeperTip > maxExecFee || maxExecFee > amount / 2) revert BadParams();

        planId = _plans.length;
        _plans.push(Plan(msg.sender, token, amount, period, keeperTip, maxExecFee, true, name));
        _plansOf[msg.sender].push(planId);
        emit PlanCreated(planId, msg.sender, token, amount, period, name);
    }

    /// @notice Stop a plan. No new subscriptions and no further payments, permanently.
    function closePlan(uint256 planId) external {
        Plan storage p = _plans[planId];
        if (msg.sender != p.merchant) revert NotAuthorized();
        if (!p.active) revert PlanInactive();
        p.active = false;
        emit PlanClosed(planId);
    }

    // ───────────────────────────── payers ────────────────────────────

    /// @notice Subscribe and pay the first period now. Requires an allowance of at least `amount`.
    ///         A payer who cancelled and returns before their paid time ran out is not charged
    ///         again until it does.
    /// @param ref free-form reference the merchant can reconcile against (order id, user id…)
    function subscribe(uint256 planId, bytes32 ref) external nonReentrant returns (uint256 orderId) {
        Plan storage p = _plans[planId];
        if (!p.active) revert PlanInactive();
        if (_liveOrder[planId][msg.sender] != 0) revert AlreadySubscribed();

        uint40 nextDue = paidUntil[planId][msg.sender];
        bool prepaid = nextDue > block.timestamp;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (!prepaid) nextDue = uint40(block.timestamp + p.period); // safe: fits 40 bits

        orderId = _orders.length;
        // forge-lint: disable-next-line(unsafe-typecast)
        _orders.push(Order(uint64(planId), msg.sender, nextDue, uint40(block.timestamp), prepaid ? 0 : 1, true));
        _ordersOf[msg.sender].push(orderId);
        _ordersOfPlan[planId].push(orderId);
        _liveOrder[planId][msg.sender] = orderId + 1;
        emit Subscribed(orderId, planId, msg.sender, ref);
        if (prepaid) return orderId;

        paidUntil[planId][msg.sender] = nextDue;
        _pull(p.token, msg.sender, p.amount);
        _settle(orderId, planId, p, address(0), 0, nextDue);
    }

    /// @notice End an order. The payer can always leave; the merchant can also end it.
    function cancel(uint256 orderId) external {
        Order storage o = _orders[orderId];
        if (!o.active) revert OrderInactive();
        if (msg.sender != o.payer && msg.sender != _plans[o.planId].merchant) revert NotAuthorized();
        o.active = false;
        delete _liveOrder[o.planId][o.payer];
        emit Cancelled(orderId, msg.sender);
    }

    // ─────────────────────────── executors ───────────────────────────

    /// @notice Execute a due payment. Open to anyone; the caller is refunded gas plus the tip.
    function execute(uint256 orderId) external nonReentrant {
        _execute(orderId, msg.sender, gasleft());
    }

    /// @notice Execute many orders in one transaction. Each order is attempted in isolation, so
    ///         one that is not due, was cancelled, or cannot be paid is skipped, not fatal.
    /// @return paid number of payments that went through
    function executeBatch(uint256[] calldata orderIds) external nonReentrant returns (uint256 paid) {
        for (uint256 i; i < orderIds.length; ++i) {
            if (gasleft() < MIN_GAS_PER_ORDER) revert InsufficientGas();
            try this.executeFor(orderIds[i], msg.sender) {
                ++paid;
            } catch {}
        }
    }

    /// @dev Batch helper. External only so that a failing order can revert on its own.
    function executeFor(uint256 orderId, address executor) external {
        if (msg.sender != address(this)) revert NotAuthorized();
        _execute(orderId, executor, gasleft());
    }

    // ───────────────────────────── views ─────────────────────────────

    function planCount() external view returns (uint256) {
        return _plans.length;
    }

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function getPlan(uint256 planId) external view returns (Plan memory) {
        return _plans[planId];
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function plansOf(address merchant) external view returns (uint256[] memory) {
        return _plansOf[merchant];
    }

    function ordersOf(address payer) external view returns (uint256[] memory) {
        return _ordersOf[payer];
    }

    function ordersOfPlan(uint256 planId) external view returns (uint256[] memory) {
        return _ordersOfPlan[planId];
    }

    /// @notice The integration point for merchants: has this account paid for the present moment?
    ///         True through the end of the last period paid for, even after a cancellation.
    /// @param grace seconds of lateness tolerated for an account that is still subscribed
    function isCurrent(uint256 planId, address payer, uint32 grace) external view returns (bool) {
        uint256 until = paidUntil[planId][payer];
        if (_liveOrder[planId][payer] != 0 && _plans[planId].active) until += grace;
        return block.timestamp < until;
    }

    /// @notice The payer's live order on a plan, if any.
    function liveOrderOf(uint256 planId, address payer) external view returns (bool live, uint256 orderId) {
        uint256 slot = _liveOrder[planId][payer];
        return slot == 0 ? (false, 0) : (true, slot - 1);
    }

    /// @notice Orders in `[from, from + count)` worth executing right now: due, live, backed by
    ///         enough balance and allowance, and paying the executor at least `minExecFee`.
    ///         Lets a keeper run with no indexer. It is a filter, not a guarantee — several orders
    ///         can share one allowance, so keepers should still simulate before sending.
    /// @param minExecFee smallest fee (token units) worth the executor's while; filters out plans
    ///        whose cap would leave it out of pocket
    function executable(uint256 from, uint256 count, uint256 minExecFee) external view returns (uint256[] memory ids) {
        uint256 end = from + count;
        if (end > _orders.length) end = _orders.length;
        if (from >= end) return ids;
        ids = new uint256[](end - from);
        uint256 n;
        for (uint256 i = from; i < end; ++i) {
            Order storage o = _orders[i];
            Plan storage p = _plans[o.planId];
            if (!o.active || !p.active || block.timestamp < o.nextDue) continue;
            if (_execFee(p, TYPICAL_EXEC_GAS) < minExecFee) continue;
            if (IERC20(p.token).balanceOf(o.payer) < p.amount) continue;
            if (IERC20(p.token).allowance(o.payer, address(this)) < p.amount) continue;
            ids[n++] = i;
        }
        assembly {
            mstore(ids, n)
        }
    }

    /// @notice What an executor would be paid for one payment on this plan at the current base fee.
    function quoteExecFee(uint256 planId, uint256 gasUsed) external view returns (uint256) {
        return _execFee(_plans[planId], gasUsed);
    }

    // ───────────────────────────── admin ─────────────────────────────

    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        tokenAllowed[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert BadParams();
        feeBps = feeBps_;
        emit FeeChanged(feeBps_);
    }

    function withdrawFees(address token, address to) external onlyOwner nonReentrant {
        uint256 amount = accruedFees[token];
        accruedFees[token] = 0;
        _send(token, to, amount);
        emit FeesWithdrawn(token, to, amount);
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotAuthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ─────────────────────────── internals ───────────────────────────

    /// @dev A payment collected on time, or a little late, keeps the billing date. One collected
    ///      later than the tolerance restarts the schedule from now, so every payment buys close to
    ///      a full period and a payer who was unreachable for months is charged once, not per month.
    ///      State is updated before the token is touched.
    function _execute(uint256 orderId, address executor, uint256 gasStart) internal {
        Order storage o = _orders[orderId];
        if (!o.active) revert OrderInactive();
        Plan storage p = _plans[o.planId];
        if (!p.active) revert PlanInactive();
        if (block.timestamp < o.nextDue) revert NotDue(o.nextDue);

        uint256 tolerance = p.period / 4;
        if (tolerance > MAX_LATE_TOLERANCE) tolerance = MAX_LATE_TOLERANCE;
        uint256 next = (block.timestamp - o.nextDue > tolerance ? block.timestamp : o.nextDue) + p.period;
        // forge-lint: disable-next-line(unsafe-typecast)
        o.nextDue = uint40(next); // safe: a timestamp plus a uint32 period fits 40 bits
        paidUntil[o.planId][o.payer] = o.nextDue;
        ++o.payments;

        uint256 overhead = ORDER_OVERHEAD;
        if (!_txOverheadRefunded) {
            _txOverheadRefunded = true;
            overhead += TX_OVERHEAD;
        }

        _pull(p.token, o.payer, p.amount);
        _settle(orderId, o.planId, p, executor, gasStart - gasleft() + overhead, o.nextDue);
    }

    /// @dev Splits a payment already held by this contract between merchant, executor and protocol.
    function _settle(uint256 orderId, uint256 planId, Plan storage p, address executor, uint256 gasUsed, uint40 nextDue)
        internal
    {
        uint256 amount = p.amount;
        uint256 protocolFee = amount * feeBps / 10_000;
        uint256 execFee = executor == address(0) ? 0 : _execFee(p, gasUsed);
        uint256 net = amount - protocolFee - execFee;

        accruedFees[p.token] += protocolFee;
        _send(p.token, p.merchant, net);
        if (execFee != 0) _send(p.token, executor, execFee);
        emit Paid(orderId, planId, executor, amount, net, protocolFee, execFee, nextDue);
    }

    /// @dev Gas is refunded at `block.basefee`, not `tx.gasprice`, so an executor cannot raise
    ///      its own refund by overbidding. Only USDC plans get a gas refund; for other tokens
    ///      there is no oracle-free conversion, so the executor earns the flat tip alone.
    function _execFee(Plan storage p, uint256 gasUsed) internal view returns (uint256 fee) {
        fee = p.keeperTip;
        if (p.token == USDC) {
            uint256 costNative = gasUsed * block.basefee;
            fee += (costNative + NATIVE_TO_ERC20 - 1) / NATIVE_TO_ERC20; // round up to 6 decimals
        }
        if (fee > p.maxExecFee) fee = p.maxExecFee;
    }

    /// @dev Pulls `amount` and verifies it arrived in full, so a token that skims transfers
    ///      can never be paid out from other plans' fees.
    function _pull(address token, address from, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        (bool ok, bytes memory ret) =
            token.call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert PullFailed();
        if (IERC20(token).balanceOf(address(this)) - before != amount) revert PullFailed();
    }

    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}
