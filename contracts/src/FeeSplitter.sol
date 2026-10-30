// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FeeSplitter
/// @notice Holds the Trading Post integrator fee (20 bps on KyberSwap, Velora and Relay swaps on Robinhood Chain
///         4663) and pays the whole balance out in five legs. Anyone calls `distribute(token)`. `address(0)` is
///         native ETH, which arrives through `receive()`. Launch shares, set in the constructor and not hardcoded
///         as constants: 40% purses, 25% Locksley Vault, 15% weekly swapper rebate, 10% buy-and-burn, 10% toll/ops.
///
///         Each of the first four legs is `balance * bps / 10_000`, rounded down. The ops leg is the remainder, so
///         it receives its own share plus at most 4 wei of dust from the other floors, and the balance always
///         clears. A split with `opsBps == 0` still pays that dust to the ops recipient.
///
///         Buy-and-burn: if `token` is the immutable `$wif` passed to the constructor, that leg goes to
///         `0x000000000000000000000000000000000000dEaD`. Every other token, including ETH, is forwarded to
///         `burnBuyer`. This contract does not swap and holds no second ledger. Keeping the non-`$wif` share here
///         would make the next `distribute` split it again, so forwarding it to `burnBuyer` (the later buyer) is
///         the smaller safe design. This assumes a standard token: a fee taken inside `transfer` can make the last
///         leg fail, and that leg is escrowed (below).
///
///         A3-09 / A3-10: a leg whose send fails (a recipient that rejects ETH, a blocklisted or frozen recipient, a
///         paused token, a recipient that burns its gas) no longer reverts the call. That leg is escrowed in
///         `owed[token][recipient]` and the other legs are paid. Escrow is excluded from the next split. Anyone
///         can retry it with `claimEscrow` (pays only that recipient). The Safe can move it elsewhere with
///         `queueRescue` / 7 days / `executeRescue`, for at most the amount owed when it was queued. A token that freezes this contract itself cannot be rescued
///         on-chain; only the issuer can unfreeze it.
///
///         The owner is the Safe. Recipients and the split change only through `queue` / 7 days / `execute`, or
///         `cancel`. The id is `keccak256(abi.encode(op, key, value))`, the same shape as RakeBuyer. There is no
///         setup bypass. The only outbound calls are `IERC20.transfer` (SafeERC20) and an ETH send with empty
///         calldata. No arbitrary call, no router, no sweep that skips the split.
///
///         Where the legs should point. This contract does not hardcode them.
///         - Purses: not FairCore, LastArrow or SheriffsSeat. A plain transfer is not a purse. FairCore credits a
///           purse only in `collect`, which is `onlyBooth`, pulls USDG only, and keeps `purseBps` of the amount
///           (the rest is Greenwood). USDG above `accounted`, and any other token, is uncounted and `sweepExcess`
///           can take it. The booths read `FairCore.pot`; they do not custody the prize. Point this leg at a
///           Safe-held address. The minimal later fix, not in this contract, is a `FairCore.creditPurse` that adds
///           a full USDG amount to `pot[booth][roundKey]` and to `accounted`. `claim` pays USDG only, so a
///           non-USDG fee still has to be swapped to USDG before that call.
///         - Vault: LocksleyVault, for ERC-20s. It has no token ledger. `heldOf` and `pull` both use `balanceOf`,
///           so a plain transfer is the whole top-up and the future launcher can take it. That balance is not
///           FairCore's `vaultLiqUsdg` / `vaultFairsBurnUsdg` ledger (those move only through `collect` and
///           `releaseVaultUsdg`). LocksleyVault has no `receive`, and `pull` cannot move ETH, so the vault's ETH
///           leg fails. Since A3-09 that leg is escrowed in `owed[address(0)][vault]` and the other four ETH legs
///           are paid; the Safe can move the escrowed ETH with `queueRescue` / 7 days / `executeRescue`.
///         - Rebate: a holding address. The weekly payout is post-hackathon; this contract only forwards the share.
contract FeeSplitter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice Every recipient or split change waits this long. Not configurable.
    uint256 public constant TIMELOCK = 7 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice Gas forwarded to each leg's send in `distribute`. A leg that needs more is escrowed, and
    ///         `claimEscrow` retries it with all the gas the caller sends.
    uint256 public constant LEG_GAS = 200_000;

    /// @notice `SetSplit` carries the five bps in `key` (`packSplit`) and `value` must be `address(0)`.
    ///         Every other op carries the new recipient in `value` and `key` must be 0.
    enum Op {
        SetPurses,
        SetVault,
        SetRebate,
        SetBurnBuyer,
        SetOps,
        SetSplit
    }

    struct Recipients {
        address purses;
        address vault;
        address rebate;
        address burnBuyer;
        address ops;
    }

    struct FeeSplit {
        uint16 pursesBps;
        uint16 vaultBps;
        uint16 rebateBps;
        uint16 burnBps;
        uint16 opsBps;
    }

    /// @notice `$wif`. The burn leg of this token is sent to `DEAD`. Immutable on purpose.
    address public immutable wif;

    address public purses;
    address public vault;
    address public rebate;
    address public burnBuyer;
    address public ops;

    uint16 public pursesBps;
    uint16 public vaultBps;
    uint16 public rebateBps;
    uint16 public burnBps;
    uint16 public opsBps;

    /// @notice op id => earliest `execute` timestamp. 0 means not queued. Re-queueing the same id resets the wait.
    mapping(bytes32 => uint256) public queuedAt;

    /// @notice A3-09/A3-10: legs whose send failed, per token and recipient. Not split again.
    mapping(address => mapping(address => uint256)) public owed;
    /// @notice Sum of `owed[token][*]`.
    mapping(address => uint256) public escrowTotal;
    /// @notice K16v2-01: bumped whenever `owed[token][from]` is paid out (claim or rescue). A rescue id includes it,
    ///         so a rescue queued before a payout can't later move escrow that arrived after it.
    mapping(address => mapping(address => uint256)) public escrowEpoch;

    event Distributed(
        address indexed token,
        address indexed burnTo,
        uint256 toPurses,
        uint256 toVault,
        uint256 toRebate,
        uint256 toBurn,
        uint256 toOps
    );
    event ChangeQueued(bytes32 indexed id, Op op, uint256 key, address value, uint256 eta);
    event ChangeExecuted(bytes32 indexed id, Op op, uint256 key, address value);
    event ChangeCancelled(bytes32 indexed id);
    event RecipientUpdated(Op indexed op, address value);
    event SplitUpdated(uint16 pursesBps, uint16 vaultBps, uint16 rebateBps, uint16 burnBps, uint16 opsBps);
    event LegEscrowed(address indexed token, address indexed to, uint256 amount);
    event EscrowClaimed(address indexed token, address indexed to, uint256 amount);
    event RescueQueued(
        bytes32 indexed id, address indexed token, address indexed from, address to, uint256 amount, uint256 eta
    );
    event Rescued(address indexed token, address indexed from, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadRecipient();
    error BadSplit();
    error BadValue();
    error ZeroAmount();
    error NotQueued();
    error TooEarly(uint256 eta);
    error EthTransferFailed();
    error RenounceDisabled();
    error InsufficientGas();

    constructor(address wif_, address owner_, Recipients memory recipients_, FeeSplit memory split_) Ownable(owner_) {
        if (wif_ == address(0)) revert ZeroAddress();
        wif = wif_;
        _setRecipients(recipients_);
        _setSplit(split_);
    }

    /// @notice Accept ETH. Distribution is a separate call so a reverting recipient cannot brick the receive.
    receive() external payable {}

    // ================================================================== views

    /// @notice The five amounts and the burn destination for the current balance. A zero balance quotes zeros.
    function quote(address token)
        external
        view
        returns (uint256 toPurses, uint256 toVault, uint256 toRebate, uint256 toBurn, uint256 toOps, address burnTo)
    {
        (toPurses, toVault, toRebate, toBurn, toOps) = _amounts(_splittable(token));
        burnTo = _burnTo(token);
    }

    /// @notice Id of a rescue at the current escrow epoch of `from`. Use it to cancel a live rescue.
    function rescueId(address token, address from, address to, uint256 amount) public view returns (bytes32) {
        return keccak256(abi.encode("rescue", token, from, to, amount, escrowEpoch[token][from]));
    }

    function opId(Op op, uint256 key, address value) public pure returns (bytes32) {
        return keccak256(abi.encode(op, key, value));
    }

    /// @notice Pack five bps into the `key` of a `SetSplit` op. Does not check the sum; `queue` does.
    function packSplit(uint16 pursesBps_, uint16 vaultBps_, uint16 rebateBps_, uint16 burnBps_, uint16 opsBps_)
        public
        pure
        returns (uint256)
    {
        return uint256(pursesBps_) | (uint256(vaultBps_) << 16) | (uint256(rebateBps_) << 32)
            | (uint256(burnBps_) << 48) | (uint256(opsBps_) << 64);
    }

    // ================================================================== distribute

    /// @notice Pay the balance of `token` (minus escrow) to the five legs. `address(0)` is ETH. Permissionless.
    ///         Amounts and recipients are snapshotted before any send. A recipient that reenters cannot
    ///         redistribute or change this call's amounts. A leg whose send fails is escrowed for that recipient.
    function distribute(address token)
        external
        nonReentrant
        returns (uint256 toPurses, uint256 toVault, uint256 toRebate, uint256 toBurn, uint256 toOps)
    {
        uint256 bal = _splittable(token);
        if (bal == 0) revert ZeroAmount();
        (toPurses, toVault, toRebate, toBurn, toOps) = _amounts(bal);
        address burnTo = _burnTo(token);
        address purses_ = purses;
        address vault_ = vault;
        address rebate_ = rebate;
        address ops_ = ops;

        _payOrEscrow(token, purses_, toPurses);
        _payOrEscrow(token, vault_, toVault);
        _payOrEscrow(token, rebate_, toRebate);
        _payOrEscrow(token, burnTo, toBurn);
        _payOrEscrow(token, ops_, toOps);
        emit Distributed(token, burnTo, toPurses, toVault, toRebate, toBurn, toOps);
    }

    /// @notice Retry an escrowed leg to the recipient it was owed to. Permissionless; pays only `to`, and reverts
    ///         (keeping the escrow) if the send still fails.
    function claimEscrow(address token, address to) external nonReentrant returns (uint256 amount) {
        amount = owed[token][to];
        if (amount == 0) revert ZeroAmount();
        owed[token][to] = 0;
        escrowTotal[token] -= amount;
        ++escrowEpoch[token][to];
        _pay(token, to, amount);
        emit EscrowClaimed(token, to, amount);
    }

    /// @notice Safe only: queue moving up to `amount` of `from`'s escrow of `token` to `to` (e.g. the recipient is
    ///         blocklisted). K16-C-A01: `amount` must be owed now, so a rescue can't be pre-armed for escrow that
    ///         doesn't exist yet; escrow that lands later needs its own queue and its own 7 days. K16v2-01: any
    ///         payout of `from`'s escrow (claim or rescue) bumps its epoch and voids rescues queued before it. Cancel
    ///         with `cancel(rescueId(token, from, to, amount))`.
    function queueRescue(address token, address from, address to, uint256 amount)
        external
        onlyOwner
        returns (bytes32 id)
    {
        _checkRecipient(to);
        if (amount == 0 || amount > owed[token][from]) revert BadValue();
        id = rescueId(token, from, to, amount);
        uint256 eta = block.timestamp + TIMELOCK;
        queuedAt[id] = eta;
        emit RescueQueued(id, token, from, to, amount, eta);
    }

    /// @notice Pay `from`'s escrow of `token` to `to`, at most the queued `amount`. Reverts NotQueued if any of
    ///         `from`'s escrow was paid out since the queue (K16v2-01), and reverts if the send fails.
    function executeRescue(address token, address from, address to, uint256 queued) external onlyOwner nonReentrant {
        bytes32 id = rescueId(token, from, to, queued);
        uint256 eta = queuedAt[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        delete queuedAt[id];
        _checkRecipient(to);
        uint256 amount = owed[token][from];
        if (amount > queued) amount = queued;
        if (amount == 0) revert ZeroAmount();
        owed[token][from] -= amount;
        escrowTotal[token] -= amount;
        ++escrowEpoch[token][from];
        _pay(token, to, amount);
        emit Rescued(token, from, to, amount);
    }

    // ================================================================== owner (Safe), 7-day timelock

    /// @notice Queue a recipient or split change. The same id again overwrites the eta, so the wait restarts.
    function queue(Op op, uint256 key, address value) external onlyOwner returns (bytes32 id) {
        _checkChange(op, key, value);
        id = opId(op, key, value);
        uint256 eta = block.timestamp + TIMELOCK;
        queuedAt[id] = eta;
        emit ChangeQueued(id, op, key, value, eta);
    }

    function cancel(bytes32 id) external onlyOwner {
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        emit ChangeCancelled(id);
    }

    /// @notice Apply a queued change once `block.timestamp >= eta`.
    function execute(Op op, uint256 key, address value) external onlyOwner {
        bytes32 id = opId(op, key, value);
        uint256 eta = queuedAt[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        delete queuedAt[id];
        _checkChange(op, key, value);
        _apply(op, key, value);
        emit ChangeExecuted(id, op, key, value);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ================================================================== internal

    function _balanceOf(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @dev Balance minus escrow, saturating (a fee-on-transfer or rebasing token could dip under the escrow).
    function _splittable(address token) internal view returns (uint256) {
        uint256 bal = _balanceOf(token);
        uint256 esc = escrowTotal[token];
        return bal > esc ? bal - esc : 0;
    }

    function _payOrEscrow(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (_tryPay(token, to, amount)) return;
        owed[token][to] += amount;
        escrowTotal[token] += amount;
        emit LegEscrowed(token, to, amount);
    }

    /// @dev One leg's send with LEG_GAS. Never reverts on the recipient's or token's behalf, so one bad leg can't
    ///      block the rest. The caller must leave enough gas for a full LEG_GAS send (EIP-150 keeps 1/64 back), so
    ///      a short-gassed call reverts instead of escrowing a healthy leg. ETH copies no return data.
    function _tryPay(address token, address to, uint256 amount) internal returns (bool ok) {
        if (gasleft() < LEG_GAS + LEG_GAS / 63 + 20_000) revert InsufficientGas();
        uint256 g = LEG_GAS;
        if (token == address(0)) {
            assembly ("memory-safe") {
                ok := call(g, to, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        uint256 rsize;
        uint256 rword;
        assembly ("memory-safe") {
            ok := call(g, token, 0, add(data, 0x20), mload(data), 0, 0x20)
            rsize := returndatasize()
            rword := mload(0)
        }
        if (!ok) return false;
        // SafeERC20's rule: no return data from a contract, or a 32-byte true.
        return rsize == 0 ? token.code.length != 0 : (rsize >= 32 && rword == 1);
    }

    function _burnTo(address token) internal view returns (address) {
        return token == wif ? DEAD : burnBuyer;
    }

    function _amounts(uint256 bal)
        internal
        view
        returns (uint256 toPurses, uint256 toVault, uint256 toRebate, uint256 toBurn, uint256 toOps)
    {
        toPurses = bal * pursesBps / BPS;
        toVault = bal * vaultBps / BPS;
        toRebate = bal * rebateBps / BPS;
        toBurn = bal * burnBps / BPS;
        // Remainder, not another floor, so sum == bal. Dust from the four floors lands here.
        toOps = bal - toPurses - toVault - toRebate - toBurn;
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, bytes memory reason) = to.call{value: amount}("");
            if (!ok) {
                if (reason.length > 0) {
                    assembly ("memory-safe") {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
                revert EthTransferFailed();
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _setRecipients(Recipients memory r) internal {
        _checkRecipient(r.purses);
        _checkRecipient(r.vault);
        _checkRecipient(r.rebate);
        _checkRecipient(r.burnBuyer);
        _checkRecipient(r.ops);
        purses = r.purses;
        vault = r.vault;
        rebate = r.rebate;
        burnBuyer = r.burnBuyer;
        ops = r.ops;
    }

    function _setSplit(FeeSplit memory s) internal {
        _checkSplit(s.pursesBps, s.vaultBps, s.rebateBps, s.burnBps, s.opsBps);
        pursesBps = s.pursesBps;
        vaultBps = s.vaultBps;
        rebateBps = s.rebateBps;
        burnBps = s.burnBps;
        opsBps = s.opsBps;
    }

    function _checkRecipient(address account) internal view {
        if (account == address(0)) revert ZeroAddress();
        // Paying this contract would leave that leg here and the next distribute would split it again.
        if (account == address(this)) revert BadRecipient();
    }

    function _checkSplit(uint16 a, uint16 b, uint16 c, uint16 d, uint16 e) internal pure {
        if (uint256(a) + b + c + d + e != BPS) revert BadSplit();
    }

    function _checkChange(Op op, uint256 key, address value) internal view {
        if (op == Op.SetSplit) {
            if (value != address(0)) revert BadValue();
            (uint16 a, uint16 b, uint16 c, uint16 d, uint16 e) = _unpack(key);
            _checkSplit(a, b, c, d, e);
        } else {
            if (key != 0) revert BadValue();
            _checkRecipient(value);
        }
    }

    function _apply(Op op, uint256 key, address value) internal {
        if (op == Op.SetSplit) {
            (uint16 a, uint16 b, uint16 c, uint16 d, uint16 e) = _unpack(key);
            _setSplit(FeeSplit(a, b, c, d, e));
            emit SplitUpdated(a, b, c, d, e);
            return;
        }
        if (op == Op.SetPurses) purses = value;
        else if (op == Op.SetVault) vault = value;
        else if (op == Op.SetRebate) rebate = value;
        else if (op == Op.SetBurnBuyer) burnBuyer = value;
        else ops = value;
        emit RecipientUpdated(op, value);
    }

    /// @dev Reject unused high bits so two different keys cannot unpack to the same split.
    function _unpack(uint256 packed) internal pure returns (uint16 a, uint16 b, uint16 c, uint16 d, uint16 e) {
        if (packed >> 80 != 0) revert BadSplit();
        a = uint16(packed);
        b = uint16(packed >> 16);
        c = uint16(packed >> 32);
        d = uint16(packed >> 48);
        e = uint16(packed >> 64);
    }
}
