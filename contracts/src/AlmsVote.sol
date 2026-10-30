// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeHandover} from "./SafeHandover.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFairCore, IFairPass} from "./interfaces/IFair.sol";

/// @title AlmsVote
/// @notice Each Fair's Alms (8% of every shot) goes to one charity the players choose. Fair Pass holders who held their
///         pass before suggestions opened, and who played that Fair, suggest charities from the allowlist and vote:
///         one wallet, one vote, for wallets that shot at least MIN_VOTE_SPEND in that Fair (A5-01). Most votes wins;
///         a tie goes to the earliest suggestion. If nobody votes, nobody
///         chooses for them: the Alms carry over to the next Fair and add to its vote, as many Fairs as it takes.
///         Release sends the USDG to the Alms Safe; the donation itself is made by hand on donate.gg and the receipt
///         is linked here. This contract never donates and holds no funds.
contract AlmsVote is SafeHandover, ReentrancyGuard {
    struct Windows {
        uint64 suggestStart;
        uint64 voteStart;
        uint64 voteEnd;
    }

    struct Result {
        bytes32 leader;
        uint32 leaderVotes;
        uint32 leaderOrder;
        uint32 suggestions;
        bool finalized;
        bytes32 winner; // zero when the Fair got no votes and its Alms carry over
        uint32 tranches;
    }

    IFairCore public immutable core;
    IFairPass public immutable fairPass;

    mapping(uint256 => Windows) public windows;
    mapping(bytes32 => uint64) public eligibleAt; // charityId = the charity's donate.gg configId (bytes32)
    mapping(uint256 => Result) public results;
    mapping(uint256 => mapping(bytes32 => uint32)) public suggestOrder; // 1-based; 0 = not suggested
    mapping(uint256 => mapping(bytes32 => uint32)) public votes;
    mapping(uint256 => mapping(address => bool)) public hasSuggested;
    mapping(uint256 => mapping(address => bool)) public voted;

    event WindowsSet(uint256 indexed fairId, uint64 suggestStart, uint64 voteStart, uint64 voteEnd);
    event WindowsCleared(uint256 indexed fairId);
    event EligibleSet(bytes32 indexed charityId, uint64 at);
    event Suggested(uint256 indexed fairId, bytes32 indexed charityId, address indexed by, uint32 order);
    event Voted(uint256 indexed fairId, bytes32 indexed charityId, address indexed voter, uint32 total);
    event Finalized(uint256 indexed fairId, bytes32 indexed winner, uint32 votes, bool carriesOver);
    /// @notice The tranche is assigned to the winning charity. Delivery is FairCore's AlmsReleased (sent) or
    ///         AlmsEscrowed (held until flushAlms). Indexers should read those for whether USDG moved (K16v2-02).
    event AlmsReleased(uint256 indexed fairId, bytes32 indexed charityId, uint256 amount, uint32 tranche);
    event AlmsCarried(uint256 indexed fromFair, uint256 indexed toFair, uint256 amount);
    event ReceiptPosted(uint256 indexed fairId, uint32 indexed tranche, bytes32 safeTxHash, string receiptUri);

    error BadWindows();
    error WindowsLocked();
    error NoWindows();
    error WrongWindow();
    error NotEligibleVoter();
    error NotPlayed();
    error BelowMinSpend(uint256 spent, uint256 needed);
    error NotEligibleCharity();
    error AlreadySuggested();
    error NotSuggested();
    error AlreadyVoted();
    error NotFinalized();
    error AlreadyFinalized();
    error RenounceDisabled();
    error ZeroId();
    error BadMinimums();

    /// @notice Windows are announced at least MIN_NOTICE before suggestions open, and suggest and vote each stay open
    ///         at least MIN_WINDOW. Both are 24 hours on mainnet (4663), enforced here. Testnet may set them shorter
    ///         so a whole Fair (suggest, vote, finalize, release) can be rehearsed in hours instead of days.
    uint64 public immutable MIN_NOTICE;
    uint64 public immutable MIN_WINDOW;
    uint64 public constant MAINNET_MIN = 24 hours;
    uint64 public constant MAX_MIN = 7 days; // sanity cap: a larger minimum would make every window unsettable

    constructor(IFairCore core_, address owner_, uint64 minNotice_, uint64 minWindow_) Ownable(owner_) {
        if (minNotice_ == 0 || minWindow_ == 0 || minNotice_ > MAX_MIN || minWindow_ > MAX_MIN) revert BadMinimums();
        if (block.chainid == 4663 && (minNotice_ < MAINNET_MIN || minWindow_ < MAINNET_MIN)) revert BadMinimums();
        core = core_;
        fairPass = core_.fairPass();
        MIN_NOTICE = minNotice_;
        MIN_WINDOW = minWindow_;
    }

    // ================================================================== owner

    uint64 public constant MAX_AFTER_FAIR = 14 days; // the vote ends within 14 days of the Fair ending

    /// @notice Set a Fair's suggest and vote windows. Locked once suggestions open. Windows must be announced
    ///         MIN_NOTICE ahead and each last at least MIN_WINDOW (a day each on mainnet), so the Safe can't run a
    ///         vote only its own wallet can catch, and the vote must close within 14 days of the Fair's end, so it
    ///         can't be postponed indefinitely.
    function setAlmsWindows(uint256 fairId, uint64 suggestStart, uint64 voteStart, uint64 voteEnd)
        external
        onlyOwner
    {
        Windows storage W = windows[fairId];
        if (results[fairId].finalized) revert AlreadyFinalized(); // no dead votes after a fallback finalize
        if (W.suggestStart != 0 && block.timestamp >= W.suggestStart) revert WindowsLocked();
        (uint64 fStart, uint64 fEnd) = core.fairs(fairId);
        if (
            fEnd == 0 || suggestStart < fStart || suggestStart < block.timestamp + MIN_NOTICE
                || voteStart < suggestStart + MIN_WINDOW || voteEnd < voteStart + MIN_WINDOW
                || voteEnd > uint256(fEnd) + MAX_AFTER_FAIR
        ) revert BadWindows();
        (W.suggestStart, W.voteStart, W.voteEnd) = (suggestStart, voteStart, voteEnd);
        emit WindowsSet(fairId, suggestStart, voteStart, voteEnd);
    }

    /// @notice Add donate.gg charities to the allowlist (from the committed eligible.json). A charity only counts for
    ///         Fairs whose suggestions open after it was added, so the list can't change under a live vote.
    function setEligible(bytes32[] calldata ids) external onlyOwner {
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == bytes32(0)) revert ZeroId();
            if (eligibleAt[ids[i]] == 0) {
                eligibleAt[ids[i]] = uint64(block.timestamp);
                emit EligibleSet(ids[i], uint64(block.timestamp));
            }
        }
    }

    /// @notice Clear a Fair's windows so the Fair can be rescheduled (e.g. the hackathon is extended). Only before the
    ///         Fair starts, so before any suggestion or vote can exist. New windows must pass every rule again
    ///         (MIN_NOTICE notice, MIN_WINDOW each, within 14 days of the end), so this gives nobody a new way to
    ///         steer the vote.
    function clearWindows(uint256 fairId) external onlyOwner {
        Windows storage W = windows[fairId];
        if (W.suggestStart == 0) revert NoWindows();
        (uint64 fStart,) = core.fairs(fairId);
        if (block.timestamp >= fStart) revert WindowsLocked();
        delete windows[fairId];
        emit WindowsCleared(fairId);
    }

    /// @notice FairCore checks this so a Fair can't be moved out from under its vote windows.
    function windowsSet(uint256 fairId) external view returns (bool) {
        return windows[fairId].suggestStart != 0;
    }

    /// @notice Link the Safe payout tx and the donate.gg receipt for a released tranche.
    function postReceipt(uint256 fairId, uint32 tranche, bytes32 safeTxHash, string calldata receiptUri)
        external
        onlyOwner
    {
        emit ReceiptPosted(fairId, tranche, safeTxHash, receiptUri);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ================================================================== players

    /// @notice A5-01 sybil damper (gameplay choice): to suggest or vote in a Fair a wallet must have put at least this
    ///         much USDG into it, net: shots credited to it (whoever paid) minus what it has won from that Fair's
    ///         rounds (K16-D-A01, FairCore.netSpentIn). Winning a solo round back no longer counts, so 5 means 5. Checked
    ///         at the moment of each suggestion or vote; a round still open then is money genuinely at risk.
    uint256 public constant MIN_VOTE_SPEND = 5e6;

    function _checkVoter(uint256 fairId, Windows storage W) internal view {
        uint64 since = fairPass.heldSince(msg.sender);
        if (since == 0 || since >= W.suggestStart) revert NotEligibleVoter(); // held from before suggestions opened
        if (!core.playedIn(fairId, msg.sender)) revert NotPlayed();
        uint256 spent = core.netSpentIn(fairId, msg.sender);
        if (spent < MIN_VOTE_SPEND) revert BelowMinSpend(spent, MIN_VOTE_SPEND);
    }

    /// @notice One suggestion per wallet per Fair, from the allowlist.
    function suggest(uint256 fairId, bytes32 id) external nonReentrant {
        if (id == bytes32(0)) revert ZeroId();
        Windows storage W = windows[fairId];
        if (W.suggestStart == 0 || block.timestamp < W.suggestStart || block.timestamp >= W.voteStart) {
            revert WrongWindow();
        }
        _checkVoter(fairId, W);
        uint64 e = eligibleAt[id];
        if (e == 0 || e >= W.suggestStart) revert NotEligibleCharity(); // listed before suggestions opened
        if (hasSuggested[fairId][msg.sender] || suggestOrder[fairId][id] != 0) revert AlreadySuggested();
        hasSuggested[fairId][msg.sender] = true;
        Result storage R = results[fairId];
        uint32 order = ++R.suggestions;
        suggestOrder[fairId][id] = order;
        emit Suggested(fairId, id, msg.sender, order);
    }

    /// @notice One vote per wallet per Fair. The leader is tracked as votes come in, so finalising needs no loop.
    function vote(uint256 fairId, bytes32 id) external nonReentrant {
        Windows storage W = windows[fairId];
        if (block.timestamp < W.voteStart || block.timestamp >= W.voteEnd) revert WrongWindow();
        _checkVoter(fairId, W);
        uint32 order = suggestOrder[fairId][id];
        if (order == 0) revert NotSuggested();
        if (voted[fairId][msg.sender]) revert AlreadyVoted();
        voted[fairId][msg.sender] = true;
        uint32 v = ++votes[fairId][id];
        Result storage R = results[fairId];
        // Most votes; on a tie the earlier suggestion keeps the lead.
        if (v > R.leaderVotes || (v == R.leaderVotes && order < R.leaderOrder)) {
            (R.leader, R.leaderVotes, R.leaderOrder) = (id, v, order);
        }
        emit Voted(fairId, id, msg.sender, v);
    }

    // ================================================================== anyone

    uint256 public constant NO_WINDOWS_GRACE = 7 days;

    /// @notice After the vote closes. Most votes wins. Zero votes (or no suggestions): no winner, the Alms carry over.
    ///         If a Fair's windows were never set, anyone can finalize it 7 days after it ends, as a zero-vote Fair,
    ///         so its Alms roll forward without anyone's say-so.
    function finalize(uint256 fairId) external nonReentrant {
        Windows storage W = windows[fairId];
        if (W.voteEnd == 0) {
            (, uint64 end) = core.fairs(fairId);
            if (end == 0 || block.timestamp < uint256(end) + NO_WINDOWS_GRACE) revert WrongWindow();
        } else if (block.timestamp < W.voteEnd) {
            revert WrongWindow();
        }
        Result storage R = results[fairId];
        if (R.finalized) revert AlreadyFinalized();
        R.finalized = true;
        R.winner = R.leaderVotes == 0 ? bytes32(0) : R.leader;
        emit Finalized(fairId, R.winner, R.leaderVotes, R.winner == bytes32(0));
    }

    /// @notice Anyone, after finalize. With a winner: send this Fair's Alms to the Alms Safe for that charity. With no
    ///         votes: carry them into the next Fair's Alms. Can be called again later for shots that came after
    ///         (tranches); every tranche follows the same outcome.
    function releaseAlms(uint256 fairId) external nonReentrant returns (uint256 amount) {
        Result storage R = results[fairId];
        if (!R.finalized) revert NotFinalized();
        if (R.winner == bytes32(0)) {
            amount = core.carryAlms(fairId);
            if (amount != 0) emit AlmsCarried(fairId, fairId + 1, amount);
        } else {
            amount = core.releaseAlms(fairId);
            if (amount != 0) emit AlmsReleased(fairId, R.winner, amount, ++R.tranches);
        }
    }
}
