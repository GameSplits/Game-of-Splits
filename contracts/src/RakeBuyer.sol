// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeHandover} from "./SafeHandover.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBuyRoute, IGameConfig} from "./interfaces/IFair.sol";

/// @title RakeBuyer
/// @notice Receives Robin Among Thieves' rake in USDG. Half of what arrives buys GameConfig's buy token in small keeper
///         chunks; the other half is kept as the USDG leg. forward() sends the bought tokens and the matching USDG to
///         LocksleyVault, whose launcher pairs them into liquidity. RakeBuyer never adds liquidity itself.
///         Buys use FairCore's floor: minOut at least 95% of a price anchor that rises with the keeper's quote by
///         at most 2% per 4-hour window, and only falls with time (1% per hour, at most 30%). It is seeded by the
///         Safe, and belongs to the GameConfig epoch it was set in.
///         GameConfig is the Safe-owned config with a 7-day timelock.
contract RakeBuyer is SafeHandover, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_BUY_USDG = 50e6; // per keeper call
    uint64 public constant MIN_BUY_GAP = 50 minutes;
    /// @notice A3-19: at most this much USDG buys per UTC day (10 full buys), like FairCore.DAILY_SWAP_CAP. Bounds what a
    ///         compromised keeper can push through the floor in a day.
    uint256 public constant DAILY_BUY_CAP = 500e6;
    uint256 public constant RATCHET_BPS = 9500;
    uint256 public constant ANCHOR_DECAY_BPS_PER_HOUR = 100;
    uint256 public constant MAX_ANCHOR_RAISE_BPS = 200; // the anchor rises by at most 2% per RAISE_WINDOW
    uint64 public constant RAISE_WINDOW = 4 hours; // slower than the 1%/hour decay
    uint256 public constant MAX_DECAY_BPS = 3000;
    /// @notice A1-12: same rule as FairCore.MAX_RESET_BPS. After setup a reset is timelocked and, while an anchor is
    ///         live in this epoch, lands within ±30% of the stored (undecayed) anchor at execute time; with no live
    ///         anchor (a new epoch) it is unbounded but still timelocked.
    uint256 public constant MAX_RESET_BPS = 3000;
    uint256 public constant MAINNET_TIMELOCK = 48 hours;

    enum Op {
        SetKeeper,
        SetRoute,
        ResetRatchet, // appended (A1-12): key = the new anchor, value = address(0)
        SetForwardTo // appended (K-C01): key = 0, value = where forwards go (address(0) = back to `vault`)
    }

    IERC20 public immutable usdg;
    IGameConfig public immutable config;
    address public immutable vault;
    uint256 public immutable timelockDelay;

    address public keeper;
    mapping(uint256 => IBuyRoute) public routes;
    bool public setupDone;
    mapping(bytes32 => uint256) public queuedAt;
    /// @notice The one ResetRatchet op that may be pending (0 = none): resets can't be stacked to walk the anchor.
    bytes32 public pendingReset;

    uint256 public buyPending; // USDG waiting to buy the buy token
    uint256 public legPending; // USDG kept as the liquidity leg
    mapping(address => uint256) public bought; // token bought and not yet forwarded
    mapping(address => uint256) public spentOf; // USDG spent on that token since its last forward
    /// @notice K-C02: the sum of every spentOf. `reconcile` must list tokens whose spentOf adds up to it.
    uint256 public totalSpent;
    /// @notice A3-19: USDG bought per UTC day.
    mapping(uint256 => uint256) public boughtOnDay;
    /// @notice K-C01: timelocked alternate forward recipient (e.g. if USDG blocklists the vault). 0 = `vault`.
    address public forwardTo;

    uint256 public anchorRate; // buy-token wei per USDG unit, x1e18
    uint64 public anchorAt;
    uint64 public anchorEpoch;
    /// @notice Decayed anchor at the start of the current raise window. Quotes in the window cannot lift the
    ///         anchor above `raiseBase * (BPS + MAX_ANCHOR_RAISE_BPS) / BPS`.
    uint256 public raiseBase;
    uint64 public raiseWindowStart;
    uint64 public lastBuyAt;
    /// @notice M-2: high-water anchor in the current GameConfig epoch. Set by every reset and raised whenever a quote
    ///         lands above it. `decayedAnchor()` never goes below 70% of it, and reset bounds are measured from it.
    uint256 public anchorBase;

    event Received(uint256 amount, uint256 toBuy, uint256 toLeg);
    event Bought(address indexed token, uint256 route, uint256 usdgIn, uint256 out, uint256 minOut);
    event Forwarded(address indexed token, address indexed to, uint256 tokenAmount, uint256 usdgAmount);
    event KeeperSet(address indexed keeper);
    event RouteSet(uint256 indexed index, address route);
    event RatchetReset(uint256 newAnchor, uint64 epoch);
    event OpQueued(bytes32 indexed id, Op op, uint256 key, address value, uint256 eta);
    event OpExecuted(bytes32 indexed id, Op op, uint256 key, address value);
    event OpCancelled(bytes32 indexed id);
    event SetupDone();
    event ExcessSwept(address indexed token, address indexed to, uint256 amount);
    event Reconciled(uint256 balance, uint256 buyPending, uint256 legPending);
    event ForwardToSet(address to);
    event ForwardFailed(address indexed token, address indexed asset, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ConfigMismatch();
    error NotKeeper();
    error OverCap();
    error OverLedger();
    error ZeroMinOut();
    error TooSoon(uint256 next);
    error NotSeeded();
    error RatchetTripped(uint256 minOut, uint256 floor);
    error NoRoute();
    error RouteTokenMismatch();
    error ShortFill(uint256 got, uint256 minOut);
    error NothingToForward();
    error SetupClosed();
    error SetupOpen();
    error NotQueued();
    error TooEarly(uint256 eta);
    error RenounceDisabled();
    error BadTokens();
    error BadOpValue();
    error ResetOutOfBounds(uint256 newAnchor, uint256 lo, uint256 hi);
    error ResetPending(bytes32 id);
    error DailyCap();

    /// @param timelockDelay_ at least 48h on mainnet (4663).
    constructor(IERC20 usdg_, IGameConfig config_, address vault_, address owner_, uint256 timelockDelay_)
        Ownable(owner_)
    {
        if (address(usdg_) == address(0) || address(config_) == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }
        if (config_.usdg() != address(usdg_)) revert ConfigMismatch();
        if (block.chainid == 4663 && timelockDelay_ < MAINNET_TIMELOCK) revert TooEarly(MAINNET_TIMELOCK);
        usdg = usdg_;
        config = config_;
        vault = vault_;
        timelockDelay = timelockDelay_;
    }

    // ================================================================== views

    function buyToken() public view returns (address t) {
        (,, t) = config.tokens();
    }

    function decayedAnchor() public view returns (uint256) {
        uint256 a = anchorRate;
        if (a == 0 || anchorEpoch != config.epoch()) return 0;
        uint256 decay = (block.timestamp - anchorAt) * ANCHOR_DECAY_BPS_PER_HOUR / 1 hours;
        if (decay > MAX_DECAY_BPS) decay = MAX_DECAY_BPS;
        uint256 d = a * (BPS - decay) / BPS;
        // M-2: lower quotes may re-anchor below the last high, but the decayed anchor never goes below 70% of the
        // high-water mark, so repeated low writes can't walk the floor under 66.5% of it without the Safe.
        uint256 stop = anchorBase * (BPS - MAX_DECAY_BPS) / BPS;
        return d < stop ? stop : d;
    }

    function ratchetFloorRate() public view returns (uint256) {
        return decayedAnchor() * RATCHET_BPS / BPS;
    }

    // ================================================================== flows

    /// @notice Splits newly arrived USDG: half to buy, half kept as the leg. Every flow below calls it first.
    ///         A balance at or under the ledgers (a wipe, a seize, a fee) splits nothing, so the call does not revert.
    function sync() public {
        uint256 bal = usdg.balanceOf(address(this));
        uint256 owed = buyPending + legPending;
        if (bal <= owed) return;
        uint256 fresh = bal - owed;
        uint256 toBuy = fresh / 2;
        buyPending += toBuy;
        legPending += fresh - toBuy;
        emit Received(fresh, toBuy, fresh - toBuy);
    }

    /// @notice Keeper only: buy the buy token with up to 50 USDG, at most once per 50 minutes, at or above the floor.
    function buy(uint256 routeIdx, uint256 usdgIn, uint256 minOut) external nonReentrant returns (uint256 out) {
        if (msg.sender != keeper) revert NotKeeper();
        sync();
        if (usdgIn == 0) revert ZeroAmount();
        if (usdgIn > MAX_BUY_USDG) revert OverCap();
        if (usdgIn > buyPending) revert OverLedger();
        if (minOut == 0) revert ZeroMinOut();
        uint256 next = uint256(lastBuyAt) + MIN_BUY_GAP;
        if (lastBuyAt != 0 && block.timestamp < next) revert TooSoon(next);
        uint256 day = block.timestamp / 1 days;
        uint256 today_ = boughtOnDay[day] + usdgIn;
        if (today_ > DAILY_BUY_CAP) revert DailyCap();
        boughtOnDay[day] = today_;
        if (anchorEpoch != config.epoch()) revert NotSeeded();
        uint256 floorRate = ratchetFloorRate();
        if (floorRate == 0) revert NotSeeded();
        uint256 floor = usdgIn * floorRate / 1e18;
        if (minOut < floor) revert RatchetTripped(minOut, floor);
        IBuyRoute r = routes[routeIdx];
        if (address(r) == address(0)) revert NoRoute();
        address tokenAddr = buyToken();
        if (r.tokenOut() != tokenAddr) revert RouteTokenMismatch();
        lastBuyAt = uint64(block.timestamp);
        buyPending -= usdgIn;
        spentOf[tokenAddr] += usdgIn;
        totalSpent += usdgIn;

        IERC20 token = IERC20(tokenAddr);
        uint256 before = token.balanceOf(address(this));
        usdg.safeTransfer(address(r), usdgIn);
        r.swapToToken(usdgIn, minOut, address(this));
        out = token.balanceOf(address(this)) - before;
        if (out < minOut) revert ShortFill(out, minOut);
        bought[tokenAddr] += out;

        // Ratchet on the keeper's quote, not the fill. A better fill must not lift the anchor:
        // one windfall, or a sandwich, would leave the floor above the market and freeze later buys.
        // The anchor cannot rise more than 2% above the decayed anchor at the start of a 4-hour
        // window. That is slower than the 1%/hour decay.
        uint256 px = minOut * 1e18 / usdgIn;
        uint256 cur = decayedAnchor();
        if (block.timestamp >= uint256(raiseWindowStart) + RAISE_WINDOW) {
            raiseBase = cur;
            raiseWindowStart = uint64(block.timestamp);
        }
        uint256 cap = raiseBase * (BPS + MAX_ANCHOR_RAISE_BPS) / BPS;
        if (px > cap) px = cap;
        if (px > cur) (anchorRate, anchorAt) = (px, uint64(block.timestamp));
        if (px > anchorBase) anchorBase = px; // M-2: the high-water mark only rises here (resets set it)
        emit Bought(tokenAddr, routeIdx, usdgIn, out, minOut);
    }

    /// @notice Sends the bought buy token and the USDG spent on it (the matching leg) to LocksleyVault. Permissionless.
    function forward() external {
        forwardToken(buyToken());
    }

    /// @notice Where forwards go: `forwardTo` if the Safe set one (timelocked), else LocksleyVault.
    function recipient() public view returns (address) {
        address f = forwardTo;
        return f == address(0) ? vault : f;
    }

    /// @notice Same for a token bought in an earlier GameConfig epoch. K-C01: the bought token and the USDG leg are
    ///         sent independently. A leg whose transfer fails (a blocklisted recipient, a paused token) stays ledgered
    ///         here for a later forward, possibly to a timelocked `forwardTo`. Reverts only if nothing could be sent.
    function forwardToken(address token) public nonReentrant {
        sync();
        uint256 amt = bought[token];
        uint256 leg = spentOf[token];
        if (amt == 0 && leg == 0) revert NothingToForward();
        address to = recipient();
        uint256 sentAmt;
        uint256 sentLeg;
        if (amt != 0) {
            bought[token] = 0;
            if (_trySend(token, to, amt)) {
                sentAmt = amt;
            } else {
                bought[token] = amt;
                emit ForwardFailed(token, token, to, amt);
            }
        }
        if (leg != 0) {
            spentOf[token] = 0;
            legPending -= leg;
            totalSpent -= leg;
            if (_trySend(address(usdg), to, leg)) {
                sentLeg = leg;
            } else {
                spentOf[token] = leg;
                legPending += leg;
                totalSpent += leg;
                emit ForwardFailed(token, address(usdg), to, leg);
            }
        }
        if (sentAmt == 0 && sentLeg == 0) revert NothingToForward();
        emit Forwarded(token, to, sentAmt, sentLeg);
    }

    /// @dev ERC-20 transfer that reports failure instead of reverting. A call that failed only because the caller
    ///      sent too little gas (EIP-150: under 1/64 left) reverts the whole forward, so nobody can force a leg to
    ///      "fail" by gas-griefing.
    function _trySend(address token, address to, uint256 amount) internal returns (bool) {
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (ok) {
            if (ret.length == 0) return token.code.length != 0;
            if (ret.length >= 32 && abi.decode(ret, (bool))) return true;
        }
        if (gasleft() < g / 64) revert NothingToForward();
        return false;
    }

    // ================================================================== owner (Safe)

    function revokeKeeper() external onlyOwner {
        keeper = address(0);
        emit KeeperSet(address(0));
    }

    /// @notice Seed the anchor during setup (wei per USDG unit, x1e18), in the current epoch. A1-12: after setup this
    ///         reverts; use queue(Op.ResetRatchet, newAnchor, address(0)) -> timelockDelay -> execute.
    function resetRatchet(uint256 newAnchor) external onlyOwner {
        if (setupDone) revert SetupClosed();
        _resetRatchet(newAnchor);
    }

    /// @notice The range a reset executed now may land in: ±MAX_RESET_BPS around `anchorBase` (before decay), or
    ///         [1, max] when no anchor is live in this GameConfig epoch.
    function resetBounds() public view returns (uint256 lo, uint256 hi) {
        // M-2: measured from the high-water mark, so a walked-down anchor can't shrink the range the Safe may restore.
        uint256 a = anchorBase;
        if (!setupDone || anchorRate == 0 || anchorEpoch != config.epoch()) return (1, type(uint256).max);
        return (a * (BPS - MAX_RESET_BPS) / BPS, a * (BPS + MAX_RESET_BPS) / BPS);
    }

    function _resetRatchet(uint256 newAnchor) internal {
        if (newAnchor == 0) revert ZeroAmount();
        (uint256 lo, uint256 hi) = resetBounds();
        if (newAnchor < lo || newAnchor > hi) revert ResetOutOfBounds(newAnchor, lo, hi);
        anchorRate = newAnchor;
        anchorAt = uint64(block.timestamp);
        anchorEpoch = config.epoch();
        raiseBase = newAnchor;
        anchorBase = newAnchor;
        raiseWindowStart = uint64(block.timestamp);
        emit RatchetReset(newAnchor, anchorEpoch);
    }

    /// @notice After USDG falls below the ledgers, write them down to the balance. Cuts buyPending first, then any
    ///         leg not matched to `tokens`, then spentOf in the order given (and the leg with it). `tokens` lists
    ///         every token with a non-zero spentOf, once each. Sends nothing, and never raises a ledger.
    function reconcile(address[] calldata tokens) external onlyOwner nonReentrant {
        uint256 bal = usdg.balanceOf(address(this));
        uint256 owed = buyPending + legPending;
        if (bal >= owed) return;

        uint256 spent;
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == tokens[i]) revert BadTokens();
            }
            spent += spentOf[tokens[i]];
        }
        // K-C02: the list must cover every token with a spentOf, or a later forward could underflow legPending.
        if (spent != totalSpent) revert BadTokens();

        uint256 deficit = owed - bal;
        uint256 fromBuy = deficit <= buyPending ? deficit : buyPending;
        buyPending -= fromBuy;
        deficit -= fromBuy;

        if (deficit != 0) {
            if (spent > legPending) revert BadTokens();
            uint256 unmatched = legPending - spent;
            if (deficit <= unmatched) {
                legPending -= deficit;
            } else {
                uint256 rest = deficit - unmatched;
                legPending -= deficit;
                for (uint256 i; i < tokens.length && rest != 0; ++i) {
                    uint256 s = spentOf[tokens[i]];
                    uint256 cut = rest <= s ? rest : s;
                    spentOf[tokens[i]] = s - cut;
                    totalSpent -= cut;
                    rest -= cut;
                }
                if (rest != 0) revert BadTokens();
            }
        }
        emit Reconciled(bal, buyPending, legPending);
    }

    /// @notice Only above the ledgers. All USDG that arrives is rake (sync), so only other tokens can have excess.
    ///         A balance under the ledgers sweeps nothing.
    function sweepExcess(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        sync();
        uint256 owed = token == address(usdg) ? buyPending + legPending : bought[token];
        uint256 balT = IERC20(token).balanceOf(address(this));
        if (balT < owed) return;
        uint256 amt = balT - owed;
        IERC20(token).safeTransfer(to, amt);
        emit ExcessSwept(token, to, amt);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Before finishSetup the owner sets the keeper and routes directly; after it, through the timelock.
    function setupSet(Op op, uint256 key, address value) external onlyOwner {
        if (setupDone) revert SetupClosed();
        _apply(op, key, value);
    }

    function finishSetup() external onlyOwner {
        if (setupDone) revert SetupClosed();
        setupDone = true;
        emit SetupDone();
    }

    function opId(Op op, uint256 key, address value) public pure returns (bytes32) {
        return keccak256(abi.encode(op, key, value));
    }

    function queue(Op op, uint256 key, address value) external onlyOwner returns (bytes32 id) {
        if (!setupDone) revert SetupOpen();
        id = opId(op, key, value);
        if (op == Op.ResetRatchet) {
            // Reset walk: one pending reset at a time, so ±MAX_RESET_BPS really is per timelockDelay.
            bytes32 p = pendingReset;
            if (p != bytes32(0) && queuedAt[p] != 0) revert ResetPending(p);
            pendingReset = id;
        }
        uint256 eta = block.timestamp + timelockDelay;
        queuedAt[id] = eta;
        emit OpQueued(id, op, key, value, eta);
    }

    function cancel(bytes32 id) external onlyOwner {
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        if (id == pendingReset) pendingReset = bytes32(0);
        emit OpCancelled(id);
    }

    function execute(Op op, uint256 key, address value) external onlyOwner {
        bytes32 id = opId(op, key, value);
        uint256 eta = queuedAt[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        delete queuedAt[id];
        if (id == pendingReset) pendingReset = bytes32(0);
        _apply(op, key, value);
        emit OpExecuted(id, op, key, value);
    }

    function _apply(Op op, uint256 key, address value) internal {
        if (op == Op.SetKeeper) {
            keeper = value; // zero allowed: turns buys off
            emit KeeperSet(value);
        } else if (op == Op.ResetRatchet) {
            if (value != address(0)) revert BadOpValue();
            _resetRatchet(key);
        } else if (op == Op.SetForwardTo) {
            if (key != 0 || value == address(this)) revert BadOpValue();
            forwardTo = value;
            emit ForwardToSet(value);
        } else {
            if (value == address(0)) revert ZeroAddress();
            routes[key] = IBuyRoute(value);
            emit RouteSet(key, value);
        }
    }
}
