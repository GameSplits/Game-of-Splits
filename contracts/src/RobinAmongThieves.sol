// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeHandover} from "./SafeHandover.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGameConfig, IArbSys, IFairCore, IFairPass} from "./interfaces/IFair.sol";
import {IIdentityRegistry, IReputationRegistry} from "./interfaces/I8004.sol";

/// @title Robin Among Thieves
/// @notice Repeated split-or-steal between outlaws (ERC-8004 agent identities). Every 30 minutes the outlaws that
///         entered are paired at random; each stakes 5 USDG, commits share or steal, then reveals. Results pay out of
///         the 10 USDG pot less a 5% rake (40% of it to the Sharing Pot, 60% to `rakeSink`), and every result is written
///         to the outlaw's ERC-8004 reputation. Registering an outlaw locks a licence in GameConfig's play token
///         (GameConfig is the Safe-owned config with a 7-day timelock); it always comes back in the token and amount
///         it was locked in. The controller also needs a Pass (the same one as the other games, read from
///         FairCore) to register and to enter a round. An operator may send `enter`; the pass checked is the
///         controller's. Committing and revealing an entry already made, and withdrawing, retiring, unbonding and
///         claiming a bond, do not check the pass, so a lapsed pass cannot trap the licence, the bond or the budget.
///         Optional bonds, disabled at launch, enabled by the
///         Safe after a 7-day timelock. All USDG is credited internally and pulled. Pausing stops `enter` only.
contract RobinAmongThieves is SafeHandover, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants
    uint256 internal constant STAKE = 5e6; // USDG, 6 dp
    uint256 internal constant RAKE = 500_000; // 5% of the 10 USDG pot
    uint256 internal constant RAKE_TO_POT = 200_000; // 40% of the rake stays in the Sharing Pot
    uint256 internal constant RAKE_OUT = RAKE - RAKE_TO_POT; // 60% goes to rakeSink
    uint256 internal constant HALF = 4_750_000; // (2 * STAKE - RAKE) / 2
    uint256 internal constant FULL = 9_500_000; // 2 * STAKE - RAKE
    uint256 internal constant BONUS_CAP = 2e6; // per player per round
    uint256 internal constant BONUS_DAILY_CAP = 6e6; // R2: per outlaw per UTC day
    uint256 internal constant ROUND_EVERY = 30 minutes;
    uint256 internal constant PAIR_DEADLINE = 3 minutes; // the keeper's seed reveal by T_r + 3m
    /// @notice A2-13: pairing (and a fallback seed) may finish until T_r + 8m; an Open round cancels only after it.
    ///         Below COMMIT_END, so a late pairing still leaves at least 5 minutes to commit.
    uint256 internal constant PAIR_LATE_DEADLINE = 8 minutes;
    /// @notice K16-B-1: a fallback seed must leave at least this long before T_r + 8m for someone to lock it (the
    ///         reveal block's hash is readable for 256 L2 blocks, about 26 seconds), so fallbackSeed closes at T_r + 7m.
    uint256 internal constant MIN_LOCK_WINDOW = 1 minutes;
    uint256 internal constant COMMIT_END = 13 minutes; // commits until T_r + 13m
    uint256 internal constant REVEAL_END = 23 minutes; // reveals in (T_r + 13m, T_r + 23m]
    uint256 internal constant PAIR_COOLDOWN = 1 hours; // the same pair meets at most once per hour
    uint256 internal constant LICENCE_MIN_HOLD = 24 hours;
    uint256 internal constant PAIR_BONUS_COOLDOWN = 24 hours; // R3
    uint256 internal constant BONUS_MIN_AGE = 24 hours; // R4
    uint256 internal constant BONUS_MIN_OPPONENTS = 5; // R4
    uint256 internal constant HOUSE_ENTRY_WINDOW = 5 minutes;
    uint256 internal constant MAX_ENTRANTS = 256;
    /// @notice RAT-01: one controller may enter at most this many outlaws in one round.
    uint256 public constant MAX_ENTRIES_PER_CONTROLLER = 3;
    uint256 internal constant MAX_DRAW_BPS = 2500; // R1
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SLASH_BPS = 1000; // 10% of a bond, when bonds are enabled
    uint256 internal constant SELF_GAS = 50_000; // gas cap for the identity approval check in settle
    uint256 public constant REP_GAS = 250_000; // gas for one reputation write; a failed write never blocks settle
    uint256 internal constant MAINNET_TIMELOCK = 48 hours;
    uint256 internal constant MAINNET_BOND_DELAY = 7 days;
    uint256 internal constant LAUNCH_LICENCE = 1000e18; // raw units of the play token
    uint256 internal constant LAUNCH_DRAW_BPS = 2500;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    IArbSys public constant ARBSYS = IArbSys(address(0x64));
    string internal constant TAG = "robinamongthieves";

    enum Choice {
        None,
        Share,
        Steal
    }

    enum Status {
        Open,
        Paired,
        Settled,
        Finalized,
        Cancelled
    }

    enum SatOutReason {
        Odd,
        Conflict,
        HouseOnly,
        Cancelled
    }

    enum Op {
        SetKeeper,
        SetRakeSink,
        SetHouseSink,
        SetLicenceAmount,
        SetDrawBps
    }

    struct Outlaw {
        address controller; // registering wallet: owns the budget, the licence and any bond
        uint64 licencedAt;
        address operator; // optional: may enter, commit and reveal only
        uint64 openRound; // 0 = none
        address licenceToken;
        uint16 distinctOpponents; // R4 counter, stops at BONUS_MIN_OPPONENTS
        bool house;
        bool retired;
        uint32 bonusDay; // R2 ledger: UTC day index
        address idOwner; // ERC-8004 owner at the last entry (for pairing)
        uint128 licenceAmount;
        uint128 balance; // free USDG budget
        address bondToken;
        uint128 bondAmount;
        uint128 bonusPaidToday;
    }

    struct Round {
        bytes32 entrantsAcc; // order-independent: XOR of keccak256(agentId, roundId)
        bytes32 pairingSeed;
        uint32 entrants;
        uint32 houseEntrants;
        uint32 cursor; // pairing: next shuffled position; cancel: next entrant to refund
        uint32 shuffled; // positions fixed by the Fisher-Yates shuffle so far
        uint32 matches;
        uint32 settled;
        uint32 eligible;
        uint32 bonusCursor;
        Status status;
        bool waiting; // pairing: an outlaw is waiting for a partner
        bool bonusFixed; // finalize: bonusPerPlayer is fixed on the first call
        uint64 seedL2Block; // L2 block of the seed reveal (ArbSys)
        uint256 waitingId;
        uint128 bonusPerPlayer;
        uint128 paidTotal;
        bool seedMixed; // first pair() has mixed the reveal block's hash into pairingSeed
    }

    struct Match {
        uint256 a;
        uint256 b;
        bytes32 commitA;
        bytes32 commitB;
        Choice revA;
        Choice revB;
        bool settled;
        bool eligA;
        bool eligB;
    }

    // ------------------------------------------------------------------ immutables
    IERC20 public immutable usdg;
    IGameConfig public immutable config;
    IFairPass public immutable fairPass;
    IIdentityRegistry public immutable identity;
    IReputationRegistry public immutable reputation;
    uint256 public immutable timelockDelay;
    uint256 public immutable bondDelay;
    uint256 public immutable genesis; // round r closes entries at genesis + r * 30 min

    // ------------------------------------------------------------------ roles and parameters
    address public keeper;
    address public rakeSink;
    address public houseSink;
    uint256 public licenceAmount;
    uint256 public drawBps;
    bool public entriesPaused;
    mapping(bytes32 => uint256) public queuedAt; // op hash => eta (0 = not queued)

    // ------------------------------------------------------------------ game state
    mapping(uint256 => Outlaw) public outlaws;
    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256[]) internal entrants;
    mapping(uint256 => mapping(uint256 => Match)) public matches;
    mapping(uint256 => mapping(uint256 => uint256)) public matchOf; // round => agentId => matchId + 1
    mapping(bytes32 => uint64) public lastMet; // pairKey => round close time
    mapping(bytes32 => uint64) public lastPairBonus; // pairKey => time a bonus was last paid (R3)
    mapping(uint256 => mapping(uint256 => bool)) public met; // R4 distinct-opponent set
    mapping(uint256 => bool) public houseRequested; // the controller asked to be a house outlaw (setHouse needs it)
    /// @notice RAT-01: how many of a controller's outlaws are entered in a round (open seats only).
    mapping(uint256 => mapping(address => uint8)) internal entriesByController; // round => controller => count

    bytes32 public seedTip; // keeper hash chain head: the next reveal must hash to it
    bytes32 public nextSeedTip; // a new chain, active from nextSeedFrom
    uint64 public nextSeedFrom;
    uint64 public lastSeedRound;
    /// @notice A2-13: rounds whose seed was revealed but never locked in time (the reveal-block hash expired).
    uint256 public pairingLapses;

    // ------------------------------------------------------------------ ledgers
    uint256 public sharingPot;
    uint256 public rakePending;
    uint256 public reservedStakes;
    uint256 public freeBalances;
    mapping(address => uint256) public lockedOf; // per token: licences + bonds
    mapping(address => uint256) public claimableOf; // per token: Σ bondClaimable
    mapping(address => uint256) public burnPending; // per token: slashed bond halves waiting to go to DEAD
    mapping(address => mapping(address => uint256)) public bondClaimable; // victim controller => token => amount

    // ------------------------------------------------------------------ bond slot
    bool public bondsEnabled;
    uint128 public minBond;
    uint256 public bondOpEta; // 0 = nothing queued
    bool public pendingBondsEnabled;
    uint128 public pendingMinBond;

    bool private _minting;

    // ------------------------------------------------------------------ events
    event OutlawRegistered(uint256 indexed agentId, address indexed controller, address operator, address token, uint256 amount);
    event OperatorSet(uint256 indexed agentId, address indexed operator);
    event Deposited(uint256 indexed agentId, address indexed from, uint256 amount);
    event Withdrawn(uint256 indexed agentId, address indexed to, uint256 amount);
    event Retired(uint256 indexed agentId, address indexed controller, address token, uint256 licence, uint256 balance);
    event Bonded(uint256 indexed agentId, address indexed token, uint256 amount);
    event Unbonded(uint256 indexed agentId, address indexed token, uint256 amount);
    event BondSlashed(uint256 indexed roundId, uint256 indexed thief, uint256 indexed victim, address token, uint256 burned, uint256 toVictim);
    event BondClaimed(address indexed to, address indexed token, uint256 amount);
    event BondBurned(address indexed token, uint256 amount);
    event BondsQueued(bool enabled, uint128 minBond, uint256 eta);
    event BondsExecuted(bool enabled, uint128 minBond);
    event BondsCancelled();
    event Entered(uint256 indexed roundId, uint256 indexed agentId, bytes32 entropy);
    event SeedChainCommitted(bytes32 tip, uint64 fromRound);
    event SeedRevealed(uint256 indexed roundId, bytes32 seed, bytes32 pairingSeed);
    event Paired(uint256 indexed roundId, uint256 indexed matchId, uint256 a, uint256 b);
    event SatOut(uint256 indexed roundId, uint256 indexed agentId, SatOutReason reason);
    event Committed(uint256 indexed roundId, uint256 indexed agentId);
    event Revealed(uint256 indexed roundId, uint256 indexed agentId, Choice choice);
    event MatchSettled(
        uint256 indexed roundId,
        uint256 indexed matchId,
        uint256 a,
        uint256 b,
        Choice choiceA,
        Choice choiceB,
        uint256 payA,
        uint256 payB,
        uint256 toPot,
        uint256 rake,
        bool eligA,
        bool eligB
    );
    event BonusPaid(uint256 indexed roundId, uint256 indexed agentId, uint256 amount);
    event RoundFinalized(uint256 indexed roundId, uint256 eligible, uint256 bonusPerPlayer, uint256 paidTotal, uint256 potAfter);
    event RoundCancelled(uint256 indexed roundId);
    event PairingLocked(uint256 indexed roundId, bytes32 pairingSeed);
    event FallbackSeeded(uint256 indexed roundId, bytes32 pairingSeed);
    event PairingLapsed(uint256 indexed roundId);
    event RakeFlushed(address indexed to, uint256 amount);
    event ReputationWriteFailed(uint256 indexed roundId, uint256 indexed agentId);
    event EntriesPaused(bool paused);
    event HouseSet(uint256 indexed agentId, bool house);
    event HouseRequested(uint256 indexed agentId);
    event KeeperSet(address indexed keeper);
    event OpQueued(bytes32 indexed id, Op op, uint256 value, address addr, uint256 eta);
    event OpExecuted(bytes32 indexed id, Op op, uint256 value, address addr);
    event OpCancelled(bytes32 indexed id);
    event ExcessSwept(address indexed token, address indexed to, uint256 amount);

    // ------------------------------------------------------------------ errors
    error ZeroAddress();
    error ZeroAmount();
    error BadDecimals();
    error ConfigMismatch();
    error BadGenesis();
    error TooEarly(uint256 eta);
    error NotQueued();
    error AlreadyPending();
    error BadValue();
    error RenounceDisabled();
    error NotKeeper();
    error NotController();
    error NotPlayer();
    error NotAgentOwner();
    error AlreadyRegistered();
    error NotRegistered();
    error NoPass();
    error TokenChanged();
    error TransferMismatch();
    error EntriesArePaused();
    error WrongRound();
    error AlreadyEntered();
    error InsufficientBalance();
    error HouseWindowClosed();
    error RoundFull();
    error TooManyEntries();
    error OpenRound();
    error LicenceHeld(uint256 until);
    error BondsDisabled();
    error BondTooSmall();
    error WrongWindow();
    error WrongStatus();
    error NotInMatch();
    error AlreadyCommitted();
    error AlreadyRevealed();
    error BadReveal();
    error NoEntrants();
    error SeedAlreadyRevealed();
    error BadSeed();
    error NoSeedChain();
    error FromTooSoon();
    error NotMinting();
    error HouseNotRequested();
    error FeedbackGas();
    error BadEntropy();
    error SeedHashUnavailable();
    error AlreadyLocked();

    // ------------------------------------------------------------------ construction
    struct Params {
        IERC20 usdg;
        IGameConfig config;
        IFairCore core; // Fair Pass is core.fairPass(), the same wiring as the other games
        IIdentityRegistry identity;
        IReputationRegistry reputation;
        address owner;
        uint256 timelockDelay; // >= 48h on mainnet (4663)
        uint256 bondDelay; // >= 7 days on mainnet (4663)
        uint256 genesis; // aligned to :00 or :30 UTC
        address keeper;
        address rakeSink;
        address houseSink;
    }

    constructor(Params memory p) Ownable(p.owner) {
        if (
            address(p.usdg) == address(0) || address(p.config) == address(0) || address(p.core) == address(0)
                || address(p.identity) == address(0) || address(p.reputation) == address(0) || p.rakeSink == address(0)
                || p.houseSink == address(0)
        ) revert ZeroAddress();
        if (IERC20Metadata(address(p.usdg)).decimals() != 6) revert BadDecimals();
        if (p.config.usdg() != address(p.usdg)) revert ConfigMismatch();
        if (block.chainid == 4663 && p.timelockDelay < MAINNET_TIMELOCK) revert TooEarly(MAINNET_TIMELOCK);
        if (block.chainid == 4663 && p.bondDelay < MAINNET_BOND_DELAY) revert TooEarly(MAINNET_BOND_DELAY);
        if (p.genesis == 0 || p.genesis % ROUND_EVERY != 0) revert BadGenesis();
        usdg = p.usdg;
        config = p.config;
        fairPass = p.core.fairPass();
        if (address(fairPass) == address(0)) revert ZeroAddress();
        identity = p.identity;
        reputation = p.reputation;
        timelockDelay = p.timelockDelay;
        bondDelay = p.bondDelay;
        genesis = p.genesis;
        keeper = p.keeper;
        rakeSink = p.rakeSink;
        houseSink = p.houseSink;
        licenceAmount = LAUNCH_LICENCE;
        drawBps = LAUNCH_DRAW_BPS;
        emit KeeperSet(p.keeper);
    }

    // ================================================================== views

    /// @notice The round taking entries now (its entries close at closeTime(r)).
    function currentRound() public view returns (uint256) {
        if (block.timestamp < genesis) return 1;
        return (block.timestamp - genesis) / ROUND_EVERY + 1;
    }

    function closeTime(uint256 roundId) public view returns (uint256) {
        return genesis + roundId * ROUND_EVERY;
    }

    function entrantsOf(uint256 roundId) external view returns (uint256[] memory) {
        return entrants[roundId];
    }

    function pairKey(uint256 a, uint256 b) public pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @notice The commit for a choice: binds it to the round, the outlaw, this contract and this chain.
    function commitHash(Choice c, bytes32 salt, uint256 roundId, uint256 agentId) public view returns (bytes32) {
        return keccak256(abi.encode(c, salt, roundId, agentId, address(this), block.chainid));
    }

    // ================================================================== outlaw lifecycle

    /// @notice Register an ERC-8004 agent you own (or are the agent wallet of) as an outlaw. The caller becomes the
    ///         controller and must hold a Pass. Locks the licence in GameConfig's play token; reverts
    ///         TokenChanged if it isn't `expectedToken` or costs more than `maxLicence`.
    function registerOutlaw(uint256 agentId, address operator, address expectedToken, uint256 maxLicence)
        external
        nonReentrant
    {
        if (!_ownsOrWallet(agentId, msg.sender)) revert NotAgentOwner();
        _register(agentId, operator, expectedToken, maxLicence);
    }

    /// @notice One-transaction onboarding: mint a new ERC-8004 identity, hand it to the caller, register it.
    ///         The caller becomes the controller and must hold a Pass. The registry clears the agent wallet on
    ///         that transfer; set it again afterwards if wanted.
    function registerOutlawNew(string calldata agentURI, address operator, address expectedToken, uint256 maxLicence)
        external
        nonReentrant
        returns (uint256 agentId)
    {
        _minting = true;
        agentId = identity.register(agentURI);
        _minting = false;
        identity.transferFrom(address(this), msg.sender, agentId);
        _register(agentId, operator, expectedToken, maxLicence);
    }

    /// @dev Accepts only the identity minted inside registerOutlawNew, which leaves again in the same call.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(identity) || !_minting) revert NotMinting();
        return this.onERC721Received.selector;
    }

    function _register(uint256 agentId, address operator, address expectedToken, uint256 maxLicence) internal {
        Outlaw storage o = outlaws[agentId];
        if (o.controller != address(0)) revert AlreadyRegistered();
        // The player is the controller this call records (msg.sender), whether that is the NFT owner or the
        // ERC-8004 agent wallet registering on the owner's behalf.
        if (!fairPass.hasPass(msg.sender)) revert NoPass();
        (address token,,) = config.tokens();
        uint256 amt = licenceAmount;
        if (token != expectedToken || amt > maxLicence) revert TokenChanged();
        o.controller = msg.sender;
        o.operator = operator;
        o.licenceToken = token;
        o.licenceAmount = uint128(amt);
        o.licencedAt = uint64(block.timestamp);
        o.retired = false;
        lockedOf[token] += amt;
        _pull(IERC20(token), msg.sender, amt);
        emit OutlawRegistered(agentId, msg.sender, operator, token, amt);
    }

    /// @notice The controller opts in to being a house outlaw (its USDG then only ever leaves to houseSink). The Safe
    ///         still has to call setHouse.
    function requestHouse(uint256 agentId) external {
        _controlled(agentId);
        houseRequested[agentId] = true;
        emit HouseRequested(agentId);
    }

    /// @notice Immediate. setOperator(id, address(0)) revokes the operator.
    function setOperator(uint256 agentId, address operator) external {
        Outlaw storage o = _controlled(agentId);
        o.operator = operator;
        emit OperatorSet(agentId, operator);
    }

    /// @notice Anyone may fund an outlaw's budget.
    function deposit(uint256 agentId, uint256 amount) external nonReentrant {
        Outlaw storage o = outlaws[agentId];
        if (o.controller == address(0)) revert NotRegistered();
        if (amount == 0) revert ZeroAmount();
        o.balance += uint128(amount);
        freeBalances += amount;
        _pull(usdg, msg.sender, amount);
        emit Deposited(agentId, msg.sender, amount);
    }

    /// @notice Controller only, free balance only, never paused. A house outlaw's USDG always goes to houseSink.
    function withdraw(uint256 agentId, uint256 amount, address to) external nonReentrant {
        Outlaw storage o = _controlled(agentId);
        if (amount == 0) revert ZeroAmount();
        if (amount > o.balance) revert InsufficientBalance();
        if (o.house) to = houseSink;
        if (to == address(0)) revert ZeroAddress();
        o.balance -= uint128(amount);
        freeBalances -= amount;
        usdg.safeTransfer(to, amount);
        emit Withdrawn(agentId, to, amount);
    }

    /// @notice No open entry, and at least 24h after registering. Returns the licence and any bond to the controller,
    ///         and the balance (to houseSink for a house outlaw).
    function retire(uint256 agentId) external nonReentrant {
        Outlaw storage o = _controlled(agentId);
        if (o.openRound != 0) revert OpenRound();
        uint256 until = uint256(o.licencedAt) + LICENCE_MIN_HOLD;
        if (block.timestamp < until) revert LicenceHeld(until);
        address ctl = o.controller;
        address lt = o.licenceToken;
        uint256 lic = o.licenceAmount;
        address bt = o.bondToken;
        uint256 bond_ = o.bondAmount;
        uint256 bal = o.balance;
        address balTo = o.house ? houseSink : ctl;
        o.controller = address(0);
        o.operator = address(0);
        o.licenceAmount = 0;
        o.licenceToken = address(0);
        o.bondAmount = 0;
        o.bondToken = address(0);
        o.balance = 0;
        o.house = false;
        houseRequested[agentId] = false;
        o.retired = true;
        lockedOf[lt] -= lic;
        freeBalances -= bal;
        if (bond_ != 0) lockedOf[bt] -= bond_;
        IERC20(lt).safeTransfer(ctl, lic);
        if (bond_ != 0) IERC20(bt).safeTransfer(ctl, bond_);
        if (bal != 0) usdg.safeTransfer(balTo, bal);
        if (bond_ != 0) emit Unbonded(agentId, bt, bond_);
        if (bal != 0) emit Withdrawn(agentId, balTo, bal);
        emit Retired(agentId, ctl, lt, lic, bal);
    }

    // ================================================================== bond slot

    /// @notice Reverts BondsDisabled until the Safe enables bonds. The token is GameConfig's play token at the first
    ///         bond, snapshotted; top-ups are in that token.
    function bond(uint256 agentId, uint256 amount, address expectedToken) external nonReentrant {
        if (!bondsEnabled) revert BondsDisabled();
        Outlaw storage o = _controlled(agentId);
        if (amount == 0) revert ZeroAmount();
        address token = o.bondAmount != 0 ? o.bondToken : _playToken();
        if (token != expectedToken) revert TokenChanged();
        uint256 total = uint256(o.bondAmount) + amount;
        if (total < minBond) revert BondTooSmall();
        o.bondToken = token;
        o.bondAmount = uint128(total);
        lockedOf[token] += amount;
        _pull(IERC20(token), msg.sender, amount);
        emit Bonded(agentId, token, amount);
    }

    /// @notice Works whether bonds are enabled or not; a no-op without a bond.
    function unbond(uint256 agentId) external nonReentrant {
        Outlaw storage o = _controlled(agentId);
        if (o.openRound != 0) revert OpenRound();
        uint256 amt = o.bondAmount;
        if (amt == 0) return;
        address token = o.bondToken;
        o.bondAmount = 0;
        o.bondToken = address(0);
        lockedOf[token] -= amt;
        IERC20(token).safeTransfer(o.controller, amt);
        emit Unbonded(agentId, token, amt);
    }

    /// @notice A victim controller's share of slashed bonds. Always works; a no-op when there is nothing.
    function claimBond(address token) external nonReentrant {
        uint256 amt = bondClaimable[msg.sender][token];
        if (amt == 0) return;
        bondClaimable[msg.sender][token] = 0;
        claimableOf[token] -= amt;
        IERC20(token).safeTransfer(msg.sender, amt);
        emit BondClaimed(msg.sender, token, amt);
    }

    /// @notice Sends the burned half of slashed bonds to DEAD. Permissionless.
    function flushBondBurn(address token) external nonReentrant {
        uint256 amt = burnPending[token];
        if (amt == 0) return;
        burnPending[token] = 0;
        IERC20(token).safeTransfer(DEAD, amt);
        emit BondBurned(token, amt);
    }

    // ================================================================== play

    /// @notice Enter the round taking entries now. Reserves STAKE from the outlaw's balance. The controller must
    ///         hold a Pass now; the caller may be the controller or the operator. A controller may enter at most
    ///         `MAX_ENTRIES_PER_CONTROLLER` outlaws in the same round (RAT-01).
    ///         `entropy` must be the one-click nonce `keccak256(abi.encode(agentId, roundId))`. Those nonces
    ///         are XORed into the accumulator, so the accumulator itself does not depend on entry order.
    ///         The shuffle still walks the `entrants` array in entry order, so order can change who meets whom.
    ///         The pairing is not fixed until `pair` mixes the L2 block hash of the reveal, which does not exist yet.
    function enter(uint256 agentId, uint256 roundId, bytes32 entropy) external {
        if (entriesPaused) revert EntriesArePaused();
        Outlaw storage o = _playable(agentId);
        if (roundId != currentRound() || block.timestamp < genesis) revert WrongRound();
        if (o.openRound != 0) revert AlreadyEntered();
        if (o.balance < STAKE) revert InsufficientBalance();
        address idOwner = identity.ownerOf(agentId);
        if (idOwner != o.controller && identity.getAgentWallet(agentId) != o.controller) revert NotAgentOwner();
        // The player is the controller, not whoever sent this transaction. A pass that lapses after registering
        // blocks a new entry; commit, reveal, withdraw and retire stay open so an in-flight round can finish and
        // the licence, bond and budget can still leave.
        if (!fairPass.hasPass(o.controller)) revert NoPass();
        Round storage r = rounds[roundId];
        if (r.entrants >= MAX_ENTRANTS) revert RoundFull();
        uint8 n = entriesByController[roundId][o.controller];
        if (n >= MAX_ENTRIES_PER_CONTROLLER) revert TooManyEntries();
        if (o.house && block.timestamp >= closeTime(roundId) - ROUND_EVERY + HOUSE_ENTRY_WINDOW) {
            revert HouseWindowClosed();
        }
        // One-click nonce, XORed into the accumulator. That hash does not depend on order; the shuffle still does.
        bytes32 nonce = keccak256(abi.encode(agentId, roundId));
        if (entropy != nonce) revert BadEntropy();
        if (o.house) r.houseEntrants++;
        o.idOwner = idOwner;
        o.openRound = uint64(roundId);
        o.balance -= uint128(STAKE);
        freeBalances -= STAKE;
        reservedStakes += STAKE;
        r.entrants++;
        r.entrantsAcc ^= nonce;
        entrants[roundId].push(agentId);
        entriesByController[roundId][o.controller] = n + 1;
        emit Entered(roundId, agentId, entropy);
    }

    function commit(uint256 roundId, uint256 agentId, bytes32 h) external {
        _playable(agentId);
        if (rounds[roundId].status != Status.Paired) revert WrongStatus();
        if (block.timestamp > closeTime(roundId) + COMMIT_END) revert WrongWindow();
        if (h == bytes32(0)) revert BadReveal();
        (Match storage m, bool isA) = _matchOf(roundId, agentId);
        if ((isA ? m.commitA : m.commitB) != bytes32(0)) revert AlreadyCommitted();
        if (isA) m.commitA = h;
        else m.commitB = h;
        emit Committed(roundId, agentId);
    }

    function reveal(uint256 roundId, uint256 agentId, Choice c, bytes32 salt) external {
        _playable(agentId);
        if (rounds[roundId].status != Status.Paired) revert WrongStatus();
        uint256 t = closeTime(roundId);
        if (block.timestamp <= t + COMMIT_END || block.timestamp > t + REVEAL_END) revert WrongWindow();
        (Match storage m, bool isA) = _matchOf(roundId, agentId);
        if ((isA ? m.revA : m.revB) != Choice.None) revert AlreadyRevealed();
        if (c == Choice.None || commitHash(c, salt, roundId, agentId) != (isA ? m.commitA : m.commitB)) {
            revert BadReveal();
        }
        if (isA) m.revA = c;
        else m.revB = c;
        emit Revealed(roundId, agentId, c);
    }

    // ================================================================== seed chain and pairing

    /// @notice The keeper commits the tip of a new hash chain (s_{i-1} = keccak256(s_i)). It takes effect from
    ///         `fromRound`, at least two rounds ahead; until then the current chain keeps working.
    function commitSeedChain(bytes32 tip, uint64 fromRound) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (tip == bytes32(0)) revert BadSeed();
        if (fromRound < currentRound() + 2) revert FromTooSoon();
        nextSeedTip = tip;
        nextSeedFrom = fromRound;
        emit SeedChainCommitted(tip, fromRound);
    }

    /// @notice Reveal round r's seed: the next preimage in the chain. Permissionless (only the keeper knows it).
    ///         Records the L2 block. The first `pair` mixes that block's hash, so this call does not fix the shuffle.
    function revealSeed(uint256 roundId, bytes32 seed) external {
        Round storage r = rounds[roundId];
        if (r.status != Status.Open) revert WrongStatus();
        uint256 t = closeTime(roundId);
        if (block.timestamp < t || block.timestamp >= t + PAIR_DEADLINE) revert WrongWindow();
        if (r.entrants == 0) revert NoEntrants();
        if (r.pairingSeed != bytes32(0) || roundId <= lastSeedRound) revert SeedAlreadyRevealed();
        if (nextSeedTip != bytes32(0) && roundId >= nextSeedFrom) {
            seedTip = nextSeedTip;
            nextSeedTip = bytes32(0);
        }
        if (seedTip == bytes32(0)) revert NoSeedChain();
        if (keccak256(abi.encode(seed)) != seedTip) revert BadSeed();
        seedTip = seed;
        lastSeedRound = uint64(roundId);
        bytes32 ps = keccak256(abi.encode(seed, r.entrantsAcc, roundId));
        r.pairingSeed = ps;
        r.seedL2Block = uint64(ARBSYS.arbBlockNumber());
        emit SeedRevealed(roundId, seed, ps);
    }

    /// @notice Pair round r's entrants, at most `maxSteps` pairings or sit-outs per call.
    ///         The first call must be in a later L2 block than `revealSeed`, and no more than 256 L2 blocks
    ///         later (about 26 seconds at ~100 ms blocks). It mixes `ArbSys.arbBlockHash` of the reveal block
    ///         into `pairingSeed` (see `lockPairing`, which does the same and should be sent first). Allowed until
    ///         T_r + 8m. Block hashes are pseudo-random and the sequencer can influence them; VRF is the full fix.
    ///         If the hash is gone unmixed, this reverts and the round lapses and refunds at T_r + 8m.
    ///         Fisher-Yates over the entrants; a pair that met within the hour, shares a controller or ERC-8004 owner,
    ///         or is two house outlaws is a conflict: the next three shuffled outlaws are tried as the partner, then
    ///         the next outlaw sits out (refunded, no rake). An odd one out sits out too.
    function pair(uint256 roundId, uint256 maxSteps) external {
        Round storage r = rounds[roundId];
        if (r.status != Status.Open || r.pairingSeed == bytes32(0)) revert WrongStatus();
        uint256 t = closeTime(roundId);
        if (block.timestamp >= t + PAIR_LATE_DEADLINE) revert WrongWindow();
        if (!r.seedMixed) _lock(r, roundId);
        uint256[] storage arr = entrants[roundId];
        uint256 n = r.entrants;
        bool houseOnly = r.houseEntrants == n;
        uint256 c = r.cursor;
        for (uint256 steps; steps < maxSteps && c < n; ++steps) {
            if (!r.waiting) {
                _fix(r, arr, c, n);
                r.waitingId = arr[c];
                r.waiting = true;
                ++c;
                if (c >= n) break;
            }
            uint256 a = r.waitingId;
            bool found;
            for (uint256 k; k < 4 && c + k < n; ++k) {
                _fix(r, arr, c + k, n);
                uint256 b = arr[c + k];
                if (!_conflict(a, b, t)) {
                    if (k != 0) (arr[c], arr[c + k]) = (b, arr[c]);
                    _makeMatch(r, roundId, a, b, t);
                    r.waiting = false;
                    found = true;
                    break;
                }
            }
            if (!found) _sitOut(roundId, arr[c], houseOnly ? SatOutReason.HouseOnly : SatOutReason.Conflict);
            ++c;
        }
        r.cursor = uint32(c);
        if (c >= n) {
            if (r.waiting) {
                r.waiting = false;
                _sitOut(roundId, r.waitingId, houseOnly ? SatOutReason.HouseOnly : SatOutReason.Odd);
            }
            if (r.matches == 0) {
                r.status = Status.Finalized;
                emit RoundFinalized(roundId, 0, 0, 0, sharingPot);
            } else {
                r.status = Status.Paired;
            }
        }
    }

    /// @notice A2-13: fix the shuffle now. Permissionless; call it in the L2 block right after `SeedRevealed` or
    ///         `FallbackSeeded`. It mixes `ArbSys.arbBlockHash` of the reveal block into `pairingSeed` (the same step
    ///         the first `pair` does). Once locked the pairing is fixed: anyone can finish it with `pair` until
    ///         T_r + 8m, and the round cannot be cancelled before then. A locked round that nobody pairs by T_r + 8m
    ///         still cancels and refunds, so the keeper must not be the only caller of `pair` (lockwatch also
    ///         calls it, L-1). Residual: the hash is only readable for 256 L2 blocks; if nobody locks in that
    ///         window the round lapses and refunds at T_r + 8m (`PairingLapsed`). The sequencer can influence
    ///         block hashes; VRF is the full fix.
    function lockPairing(uint256 roundId) external {
        Round storage r = rounds[roundId];
        if (r.status != Status.Open || r.pairingSeed == bytes32(0)) revert WrongStatus();
        if (r.seedMixed) revert AlreadyLocked();
        if (block.timestamp >= closeTime(roundId) + PAIR_LATE_DEADLINE) revert WrongWindow();
        _lock(r, roundId);
    }

    /// @notice A2-13 timeout fallback: if the keeper has not revealed by T_r + 3m, anyone may seed the round from the
    ///         entrant accumulator and a future block hash (lock it with `lockPairing` from the next L2 block), until
    ///         T_r + 7m (MIN_LOCK_WINDOW before the cancel time, so a late fallback can still be locked). A
    ///         withheld seed therefore no longer cancels the round. Not available while the keeper is revoked (the
    ///         Safe's stop): those rounds still cancel and refund. The keeper's seed chain is untouched.
    function fallbackSeed(uint256 roundId) external {
        Round storage r = rounds[roundId];
        if (r.status != Status.Open) revert WrongStatus();
        uint256 t = closeTime(roundId);
        if (block.timestamp < t + PAIR_DEADLINE || block.timestamp >= t + PAIR_LATE_DEADLINE - MIN_LOCK_WINDOW) {
            revert WrongWindow();
        }
        if (r.entrants == 0) revert NoEntrants();
        if (r.pairingSeed != bytes32(0)) revert SeedAlreadyRevealed();
        if (keeper == address(0)) revert NotKeeper();
        bytes32 ps = keccak256(abi.encode(TAG, "fallback", r.entrantsAcc, roundId));
        r.pairingSeed = ps;
        r.seedL2Block = uint64(ARBSYS.arbBlockNumber());
        emit FallbackSeeded(roundId, ps);
    }

    /// @notice An Open round cancels after T_r + 8m (A2-13; was 3m); every stake still in it goes back to its
    ///         outlaw's balance. Batched: call again until it stops refunding.
    function cancelRound(uint256 roundId, uint256 maxRefunds) external {
        Round storage r = rounds[roundId];
        if (r.status == Status.Open) {
            if (block.timestamp < closeTime(roundId) + PAIR_LATE_DEADLINE) revert WrongWindow();
            if (r.entrants == 0) revert NoEntrants();
            if (r.pairingSeed != bytes32(0) && !r.seedMixed) {
                ++pairingLapses;
                emit PairingLapsed(roundId);
            }
            r.status = Status.Cancelled;
            r.cursor = 0;
            r.waiting = false;
            emit RoundCancelled(roundId);
        } else if (r.status != Status.Cancelled) {
            revert WrongStatus();
        }
        uint256[] storage arr = entrants[roundId];
        uint256 n = r.entrants;
        uint256 c = r.cursor;
        uint256 t = closeTime(roundId);
        for (uint256 i; i < maxRefunds && c < n; ++i) {
            uint256 id = arr[c++];
            // K16-B-2: a match made before the round lapsed was never played, so its pair cooldown is rolled back.
            // Deleting is an exact rollback: the pair passed the 1h cooldown at T_r, so any earlier meeting is more
            // than an hour before every later round.
            uint256 mo = matchOf[roundId][id];
            if (mo != 0) {
                Match storage m = matches[roundId][mo - 1];
                bytes32 k = pairKey(m.a, m.b);
                if (m.a == id && lastMet[k] == uint64(t)) delete lastMet[k];
            }
            if (outlaws[id].openRound == roundId) _sitOut(roundId, id, SatOutReason.Cancelled);
        }
        r.cursor = uint32(c);
    }

    // ================================================================== settle and finalize

    /// @notice After the reveal window: pay out each match, at most `maxMatches` per call.
    function settle(uint256 roundId, uint256 maxMatches) external nonReentrant {
        Round storage r = rounds[roundId];
        if (r.status != Status.Paired) revert WrongStatus();
        if (block.timestamp <= closeTime(roundId) + REVEAL_END) revert WrongWindow();
        uint256 end = r.settled + maxMatches;
        if (end > r.matches) end = r.matches;
        for (uint256 i = r.settled; i < end; ++i) {
            _settleMatch(roundId, i);
        }
        r.settled = uint32(end);
        if (end == r.matches) r.status = Status.Settled;
    }

    /// @notice After every match is settled: pay the Sharing Pot bonus to eligible both-share players. The bonus is
    ///         fixed on the first call: min(2 USDG, pot * drawBps / 10000 / eligible), then trimmed by each outlaw's
    ///         6 USDG daily cap. At most `maxMatches` matches per call.
    function finalize(uint256 roundId, uint256 maxMatches) external nonReentrant {
        Round storage r = rounds[roundId];
        if (r.status != Status.Settled) revert WrongStatus();
        if (!r.bonusFixed) {
            r.bonusFixed = true;
            if (r.eligible != 0) {
                uint256 b = sharingPot * drawBps / BPS / r.eligible; // R1: at most drawBps of the pot this round
                r.bonusPerPlayer = uint128(b > BONUS_CAP ? BONUS_CAP : b);
            }
        }
        uint256 b_ = r.bonusPerPlayer;
        uint256 end = r.bonusCursor + maxMatches;
        if (end > r.matches) end = r.matches;
        uint256 paid;
        for (uint256 i = r.bonusCursor; i < end; ++i) {
            Match storage m = matches[roundId][i];
            if (b_ == 0 || !(m.eligA || m.eligB)) continue;
            // R3 again at payment: two rounds of one pair can both settle before either finalizes
            bytes32 key = pairKey(m.a, m.b);
            uint256 lb = lastPairBonus[key];
            if (lb != 0 && block.timestamp < lb + PAIR_BONUS_COOLDOWN) continue;
            uint256 pa = m.eligA ? _payBonus(roundId, m.a, b_) : 0;
            uint256 pb = m.eligB ? _payBonus(roundId, m.b, b_) : 0;
            if (pa != 0 || pb != 0) lastPairBonus[key] = uint64(block.timestamp);
            paid += pa + pb;
        }
        r.paidTotal += uint128(paid);
        r.bonusCursor = uint32(end);
        if (end == r.matches) {
            r.status = Status.Finalized;
            emit RoundFinalized(roundId, r.eligible, b_, r.paidTotal, sharingPot);
        }
    }

    /// @notice Sends the pending rake to rakeSink. Permissionless, never paused.
    function flushRake() external nonReentrant {
        uint256 amt = rakePending;
        if (amt == 0) return;
        rakePending = 0;
        usdg.safeTransfer(rakeSink, amt);
        emit RakeFlushed(rakeSink, amt);
    }

    // ================================================================== owner (Safe)

    /// @notice Immediate: turn off a lost or stolen keeper. Setting a new one is timelocked.
    ///         Clears `seedTip` and `nextSeedTip`. Open rounds cancel and refund, and later rounds keep
    ///         cancelling, until the new keeper commits a seed chain at least two rounds ahead.
    function revokeKeeper() external onlyOwner {
        keeper = address(0);
        seedTip = bytes32(0);
        nextSeedTip = bytes32(0);
        emit KeeperSet(address(0));
    }

    /// @notice Stops new entries only. Rounds already running always finish.
    function pauseEntries(bool paused) external onlyOwner {
        entriesPaused = paused;
        emit EntriesPaused(paused);
    }

    /// @notice House outlaws: withdrawals go to houseSink, early entry only, never paired with each other, no bonus.
    ///         Only an outlaw whose controller called requestHouse can be made one; clearing it is immediate.
    function setHouse(uint256 agentId, bool house) external onlyOwner {
        if (outlaws[agentId].controller == address(0)) revert NotRegistered();
        if (house && !houseRequested[agentId]) revert HouseNotRequested();
        outlaws[agentId].house = house;
        emit HouseSet(agentId, house);
    }

    function opId(Op op, uint256 value, address addr) public pure returns (bytes32) {
        return keccak256(abi.encode(op, value, addr));
    }

    function queue(Op op, uint256 value, address addr) external onlyOwner returns (bytes32 id) {
        _check(op, value, addr);
        id = opId(op, value, addr);
        uint256 eta = block.timestamp + timelockDelay;
        queuedAt[id] = eta;
        emit OpQueued(id, op, value, addr, eta);
    }

    function cancel(bytes32 id) external onlyOwner {
        if (queuedAt[id] == 0) revert NotQueued();
        delete queuedAt[id];
        emit OpCancelled(id);
    }

    function execute(Op op, uint256 value, address addr) external onlyOwner {
        bytes32 id = opId(op, value, addr);
        uint256 eta = queuedAt[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        delete queuedAt[id];
        if (op == Op.SetKeeper) {
            keeper = addr;
            emit KeeperSet(addr);
        } else if (op == Op.SetRakeSink) {
            rakeSink = addr;
        } else if (op == Op.SetHouseSink) {
            houseSink = addr;
        } else if (op == Op.SetLicenceAmount) {
            licenceAmount = value;
        } else {
            drawBps = value;
        }
        emit OpExecuted(id, op, value, addr); // carries the new value
    }

    /// @notice Optional bonds, disabled at launch, enabled by the Safe after a 7-day timelock. One pending change.
    function queueBonds(bool enabled, uint128 minBond_) external onlyOwner {
        if (bondOpEta != 0) revert AlreadyPending();
        uint256 eta = block.timestamp + bondDelay;
        bondOpEta = eta;
        pendingBondsEnabled = enabled;
        pendingMinBond = minBond_;
        emit BondsQueued(enabled, minBond_, eta);
    }

    function executeBonds() external onlyOwner {
        uint256 eta = bondOpEta;
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert TooEarly(eta);
        bondOpEta = 0;
        bondsEnabled = pendingBondsEnabled;
        minBond = pendingMinBond;
        emit BondsExecuted(bondsEnabled, minBond);
    }

    function cancelBonds() external onlyOwner {
        if (bondOpEta == 0) revert NotQueued();
        bondOpEta = 0;
        emit BondsCancelled();
    }

    /// @notice Only what's above every ledger: USDG above balances, stakes, pot and rake; any other token above
    ///         licences, bonds, victim claims and pending burns.
    function sweepExcess(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 owed = token == address(usdg)
            ? freeBalances + reservedStakes + sharingPot + rakePending
            : lockedOf[token] + claimableOf[token] + burnPending[token];
        uint256 amt = IERC20(token).balanceOf(address(this)) - owed;
        IERC20(token).safeTransfer(to, amt);
        emit ExcessSwept(token, to, amt);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ================================================================== internals

    function _playToken() internal view returns (address t) {
        (t,,) = config.tokens();
    }

    function _ownsOrWallet(uint256 agentId, address who) internal view returns (bool) {
        return identity.ownerOf(agentId) == who || identity.getAgentWallet(agentId) == who;
    }

    function _controlled(uint256 agentId) internal view returns (Outlaw storage o) {
        o = outlaws[agentId];
        if (o.controller == address(0) || msg.sender != o.controller) revert NotController();
    }

    function _playable(uint256 agentId) internal view returns (Outlaw storage o) {
        o = outlaws[agentId];
        if (o.controller == address(0)) revert NotRegistered();
        if (msg.sender != o.controller && msg.sender != o.operator) revert NotPlayer();
    }

    function _matchOf(uint256 roundId, uint256 agentId) internal view returns (Match storage m, bool isA) {
        uint256 mid = matchOf[roundId][agentId];
        if (mid == 0) revert NotInMatch();
        m = matches[roundId][mid - 1];
        isA = m.a == agentId;
    }

    function _pull(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert TransferMismatch();
    }

    function _check(Op op, uint256 value, address addr) internal pure {
        if ((op == Op.SetRakeSink || op == Op.SetHouseSink) && addr == address(0)) revert ZeroAddress();
        if (op == Op.SetLicenceAmount && (value == 0 || value > type(uint128).max)) revert BadValue();
        if (op == Op.SetDrawBps && value > MAX_DRAW_BPS) revert BadValue();
    }

    function _lock(Round storage r, uint256 roundId) internal {
        _mixRevealBlock(r);
        emit PairingLocked(roundId, r.pairingSeed);
    }

    /// @dev Mix the reveal block's L2 hash into the pairing seed once. The hash does not exist in the
    ///      reveal block itself, and ArbSys only keeps the last 256. A revert here leaves the round open
    ///      so it lapses and can be cancelled after PAIR_LATE_DEADLINE.
    function _mixRevealBlock(Round storage r) internal {
        uint256 nowL2 = ARBSYS.arbBlockNumber();
        uint256 revealed = r.seedL2Block;
        if (nowL2 <= revealed || nowL2 - revealed > 256) revert SeedHashUnavailable();
        bytes32 h = ARBSYS.arbBlockHash(revealed);
        if (h == bytes32(0)) revert SeedHashUnavailable();
        r.pairingSeed = keccak256(abi.encode(r.pairingSeed, h));
        r.seedMixed = true;
    }

    /// @dev Fisher-Yates, lazily: fix every shuffled position up to and including p.
    function _fix(Round storage r, uint256[] storage arr, uint256 p, uint256 n) internal {
        uint256 s = r.shuffled;
        if (s > p) return;
        bytes32 seed = r.pairingSeed;
        for (; s <= p; ++s) {
            uint256 j = s + uint256(keccak256(abi.encode(seed, s))) % (n - s);
            if (j != s) (arr[s], arr[j]) = (arr[j], arr[s]);
        }
        r.shuffled = uint32(s);
    }

    function _conflict(uint256 a, uint256 b, uint256 t) internal view returns (bool) {
        Outlaw storage oa = outlaws[a];
        Outlaw storage ob = outlaws[b];
        if (oa.house && ob.house) return true;
        if (oa.controller == ob.controller || oa.idOwner == ob.idOwner) return true;
        uint256 lm = lastMet[pairKey(a, b)];
        return lm != 0 && t < lm + PAIR_COOLDOWN;
    }

    function _makeMatch(Round storage r, uint256 roundId, uint256 a, uint256 b, uint256 t) internal {
        uint256 mid = r.matches++;
        Match storage m = matches[roundId][mid];
        m.a = a;
        m.b = b;
        matchOf[roundId][a] = mid + 1;
        matchOf[roundId][b] = mid + 1;
        lastMet[pairKey(a, b)] = uint64(t);
        emit Paired(roundId, mid, a, b);
    }

    function _sitOut(uint256 roundId, uint256 agentId, SatOutReason why) internal {
        Outlaw storage o = outlaws[agentId];
        o.openRound = 0;
        o.balance += uint128(STAKE);
        reservedStakes -= STAKE;
        freeBalances += STAKE;
        emit SatOut(roundId, agentId, why);
    }

    function _settleMatch(uint256 roundId, uint256 mid) internal {
        Match storage m = matches[roundId][mid];
        Choice ca = m.revA;
        Choice cb = m.revB;
        uint256 payA;
        uint256 payB;
        uint256 toPot = RAKE_TO_POT;
        if (ca == Choice.Share && cb == Choice.Share) {
            (payA, payB) = (HALF, HALF);
            bytes32 key = pairKey(m.a, m.b);
            bool ea = _eligible(m.a, key);
            bool eb = _eligible(m.b, key);
            (m.eligA, m.eligB) = (ea, eb);
            if (ea) rounds[roundId].eligible++;
            if (eb) rounds[roundId].eligible++;
        } else if (ca == Choice.Steal && cb == Choice.Steal) {
            toPot = 2 * STAKE - RAKE_OUT;
        } else if (ca == Choice.None && cb == Choice.None) {
            (payA, payB) = (HALF, HALF);
        } else if (cb == Choice.None || (ca == Choice.Steal && cb == Choice.Share)) {
            payA = FULL; // A stole from a sharer, or only A revealed
            if (ca == Choice.Steal && cb == Choice.Share) _slash(roundId, m.a, m.b);
        } else {
            payB = FULL; // B stole from a sharer, or only B revealed
            if (cb == Choice.Steal && ca == Choice.Share) _slash(roundId, m.b, m.a);
        }
        m.settled = true;
        reservedStakes -= 2 * STAKE;
        sharingPot += toPot;
        rakePending += RAKE_OUT;
        _credit(m.a, m.b, payA);
        _credit(m.b, m.a, payB);
        // A non-share result whose 0-score write failed because the outlaw approved this contract on its identity (the
        // registry refuses self-feedback) is forfeited to the Sharing Pot, so a steal can't be hidden from reputation.
        if (!_feedback(roundId, mid, m.a, ca) && ca != Choice.Share && payA != 0 && _selfApproved(m.a)) {
            (toPot, payA) = (toPot + _forfeit(m.a, payA), 0);
        }
        if (!_feedback(roundId, mid, m.b, cb) && cb != Choice.Share && payB != 0 && _selfApproved(m.b)) {
            (toPot, payB) = (toPot + _forfeit(m.b, payB), 0);
        }
        emit MatchSettled(roundId, mid, m.a, m.b, ca, cb, payA, payB, toPot, RAKE_OUT, m.eligA, m.eligB);
    }

    /// @dev Pays one side, clears its entry and counts the opponent toward R4 (after eligibility was decided).
    function _credit(uint256 id, uint256 opp, uint256 pay) internal {
        Outlaw storage o = outlaws[id];
        o.openRound = 0;
        if (pay != 0) {
            o.balance += uint128(pay);
            freeBalances += pay;
        }
        if (o.distinctOpponents < BONUS_MIN_OPPONENTS && !met[id][opp]) {
            met[id][opp] = true;
            o.distinctOpponents++;
        }
    }

    /// @dev R3, R4, R6 (the daily cap, R2, is applied at finalize).
    function _eligible(uint256 id, bytes32 key) internal view returns (bool) {
        Outlaw storage o = outlaws[id];
        if (o.house) return false;
        if (block.timestamp < uint256(o.licencedAt) + BONUS_MIN_AGE) return false;
        if (o.distinctOpponents < BONUS_MIN_OPPONENTS) return false;
        uint256 lb = lastPairBonus[key];
        return lb == 0 || block.timestamp >= lb + PAIR_BONUS_COOLDOWN;
    }

    function _payBonus(uint256 roundId, uint256 id, uint256 b) internal returns (uint256 pay) {
        Outlaw storage o = outlaws[id];
        // Retired between settle and finalize: leave the bonus in the Sharing Pot. Crediting it would
        // strand USDG on an outlaw with no controller (withdraw and deposit both revert).
        if (o.controller == address(0)) return 0;
        uint32 day = uint32(block.timestamp / 1 days);
        if (o.bonusDay != day) {
            o.bonusDay = day;
            o.bonusPaidToday = 0;
        }
        uint256 room = BONUS_DAILY_CAP - o.bonusPaidToday;
        pay = b < room ? b : room;
        if (pay > sharingPot) pay = sharingPot;
        if (pay == 0) return 0;
        o.bonusPaidToday += uint128(pay);
        o.balance += uint128(pay);
        freeBalances += pay;
        sharingPot -= pay;
        emit BonusPaid(roundId, id, pay);
    }

    /// @dev Only when bonds are enabled and the thief is bonded: 10%, half to DEAD (via burnPending), half to the
    ///      victim's controller (pull). While bonds are disabled no bond exists, so this never moves anything.
    function _slash(uint256 roundId, uint256 thief, uint256 victim) internal {
        Outlaw storage o = outlaws[thief];
        uint256 amt = o.bondAmount;
        if (!bondsEnabled || amt == 0) return;
        uint256 slash = amt * SLASH_BPS / BPS;
        uint256 burned = slash / 2;
        uint256 toVictim = slash - burned;
        address token = o.bondToken;
        o.bondAmount = uint128(amt - slash);
        lockedOf[token] -= slash;
        burnPending[token] += burned;
        claimableOf[token] += toVictim;
        bondClaimable[outlaws[victim].controller][token] += toVictim;
        emit BondSlashed(roundId, thief, victim, token, burned, toVictim);
    }

    /// @dev One ERC-8004 feedback per outlaw per match: 100 for share, 0 for steal or no reveal. A failure (the outlaw
    ///      approved this contract, the registry changed or has no code, the write ran out of its REP_GAS) emits
    ///      ReputationWriteFailed and settle goes on. Too little gas for the write itself reverts FeedbackGas. Returns
    ///      whether the write landed, so settle can forfeit a non-share payout the registry refused as self-feedback.
    function _feedback(uint256 roundId, uint256 mid, uint256 agentId, Choice c) internal returns (bool ok) {
        bytes memory data = abi.encodeCall(
            IReputationRegistry.giveFeedback,
            (
                agentId,
                c == Choice.Share ? int128(100) : int128(0),
                uint8(0),
                TAG,
                c == Choice.Share ? "share" : c == Choice.Steal ? "steal" : "noreveal",
                "",
                "",
                keccak256(abi.encode(roundId, mid))
            )
        );
        address rep = address(reputation);
        // settle is permissionless: refuse to run with too little gas, so a caller can't starve one outlaw's record
        // (a call only forwards 63/64 of what's left). With enough gas, a failure is the registry's, and is tolerated.
        if (gasleft() < REP_GAS * 64 / 63 + 10_000) revert FeedbackGas();
        if (rep.code.length != 0) {
            assembly ("memory-safe") {
                ok := call(REP_GAS, rep, 0, add(data, 32), mload(data), 0, 0)
            }
        }
        if (!ok) emit ReputationWriteFailed(roundId, agentId);
    }

    /// @dev Moves a just-credited payout from the outlaw's balance into the Sharing Pot.
    function _forfeit(uint256 id, uint256 pay) internal returns (uint256) {
        outlaws[id].balance -= uint128(pay);
        freeBalances -= pay;
        sharingPot += pay;
        return pay;
    }

    /// @dev True only if this contract is approved on (or owns) the identity, the case the registry refuses as
    ///      self-feedback. Bounded and fail-open: a reverting, gas-hungry or malformed identity registry reads as
    ///      false, so an outage forfeits nothing and can't block settle.
    function _selfApproved(uint256 id) internal view returns (bool y) {
        bytes memory data = abi.encodeCall(IIdentityRegistry.isAuthorizedOrOwner, (address(this), id));
        address idr = address(identity);
        if (gasleft() < SELF_GAS * 64 / 63 + 5_000) revert FeedbackGas();
        assembly ("memory-safe") {
            let s := staticcall(SELF_GAS, idr, add(data, 32), mload(data), 0, 32)
            y := and(s, and(gt(returndatasize(), 31), eq(mload(0), 1)))
        }
    }
}
