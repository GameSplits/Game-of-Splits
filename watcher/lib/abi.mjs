// Game of Splits contract ABI subset used by the keeper and the watcher (v3.7 contracts: GameConfig). Kept identical in
// keeper/src/abi.mjs and watcher/lib/abi.mjs; `node --test` in each package checks the selectors below.
import { parseAbi, toFunctionSelector } from "viem";

export const coreAbi = parseAbi([
  // keeper calls
  "function burnBuyToken(uint8 source, uint256 route, uint256 usdgIn, uint256 minOut) returns (uint256 out)",
  "function buyForVault(uint256 route, uint256 usdgIn, uint256 minOut) returns (uint256 out)",
  // reads
  "function keeper() view returns (address)",
  "function config() view returns (address)",
  "function buyToken() view returns (address)",
  "function anchorRate() view returns (uint256)",
  "function anchorAt() view returns (uint64)",
  "function anchorEpoch() view returns (uint64)",
  "function anchorStale() view returns (bool)",
  "function ratchetFloorRate() view returns (uint256)",
  "function decayedAnchor() view returns (uint256)",
  "function bonfirePending() view returns (uint256)",
  "function vaultBurnPending() view returns (uint256)",
  "function vaultBuyPending() view returns (uint256)",
  "function lastSwapAt(uint8) view returns (uint64)",
  "function swappedOnDay(uint8, uint256) view returns (uint256)",
  "function routes(uint256) view returns (address)",
  "function fairCount() view returns (uint256)",
  "function fairs(uint256) view returns (uint64 start, uint64 end)",
  "function almsByFair(uint256) view returns (uint256)",
  "function pot(address booth, uint256 roundKey) view returns (uint256)",
  "function salesPaused() view returns (bool)",
  // events the watcher reads
  "event Burned(address indexed token, uint8 indexed source, uint256 route, uint256 usdgIn, uint256 out, uint256 minOut)",
  "event BoughtForVault(address indexed token, uint256 route, uint256 usdgIn, uint256 out, uint256 minOut)",
  "event KeeperSet(address indexed keeper)",
  "event OpQueued(bytes32 indexed id, uint8 op, uint256 key, address value, uint256 eta)",
  "event OpExecuted(bytes32 indexed id, uint8 op, uint256 key, address value)",
  "event OpCancelled(bytes32 indexed id)",
  "event RatchetReset(uint256 newAnchor, uint64 epoch)",
  "event SalesPaused(bool paused)",
  "event FairSet(uint256 indexed fairId, uint64 start, uint64 end)",
  "event TollWithdrawn(address indexed to, uint256 amount)",
  "event ExcessSwept(address indexed token, address indexed to, uint256 amount)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
  "event BoothAdded(address indexed booth)",
  "event TollRecipientSet(address indexed to)",
  "event AlmsSafeSet(address indexed to)",
  "event AlmsVoteSet(address indexed almsVote)",
  "event VaultSet(address indexed vault)",
  "event RouteSet(uint256 indexed index, address route)",
  "event SetupDone()",
  "event VaultUsdgReleased(address indexed to, uint256 amount)",
  "event AlmsEscrowed(uint256 indexed fairId, address indexed to, uint256 amount)",
  // errors, so simulations decode cleanly
  "error NotKeeper()",
  "error OverLedger()",
  "error OverCap()",
  "error ZeroAmount()",
  "error ZeroMinOut()",
  "error TooSoon(uint256 next)",
  "error DailyCap()",
  "error NotSeeded()",
  "error RatchetTripped(uint256 minOut, uint256 floor)",
  "error ShortFill(uint256 got, uint256 minOut)",
  "error NoRoute()",
  "error RouteTokenMismatch()",
  "error NotVault()",
  "error NotAlmsVote()",
]);

export const arrowAbi = parseAbi([
  "function currentRound() view returns (uint256)",
  // hardEnd stays in the tuple so this matches the contract ABI. It is always 0 (no hard end); do not display it.
  // Settle from effectiveDeadline, not from hardEnd.
  "function roundState(uint256) view returns ((uint64 start, uint64 deadline, uint64 hardEnd, uint32 shots, bool settled, uint128 nextPrice, address lastShooter, uint64 lastShotL2Block, address leader, uint32 leaderCount, uint64 pauseMark))",
  "function effectiveDeadline(uint256) view returns (uint256)",
  "function settle(uint256 roundId)",
  "error NotEnded()",
  "error AlreadySettled()",
  "error NoRound()",
]);

export const seatAbi = parseAbi([
  "function today() view returns (uint256)",
  "function isSettled(uint256) view returns (bool)",
  "function settle(uint256 d)",
  "error DayNotOver()",
  "error AlreadySettled()",
]);

export const almsAbi = parseAbi([
  "function windows(uint256) view returns (uint64 suggestStart, uint64 voteStart, uint64 voteEnd)",
  "function results(uint256) view returns (bytes32 leader, uint32 leaderVotes, uint32 leaderOrder, uint32 suggestions, bool finalized, bytes32 winner, uint32 tranches)",
  "function finalize(uint256 fairId)",
  "function releaseAlms(uint256 fairId) returns (uint256 amount)",
  "event WindowsSet(uint256 indexed fairId, uint64 suggestStart, uint64 voteStart, uint64 voteEnd)",
  "event WindowsCleared(uint256 indexed fairId)",
  "event EligibleSet(bytes32 indexed charityId, uint64 at)",
  "event ReceiptPosted(uint256 indexed fairId, uint32 indexed tranche, bytes32 safeTxHash, string receiptUri)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
  "error WrongWindow()",
  "error AlreadyFinalized()",
  "error NotFinalized()",
]);

export const vaultAbi = parseAbi([
  "event LauncherQueued(address indexed launcher, uint256 eta)",
  "event LauncherCancelled(address indexed launcher)",
  "event LauncherAttached(address indexed launcher)",
  "event PulledByLauncher(address indexed launcher, address indexed token, uint256 amount)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
]);

export const passAbi = parseAbi([
  "event ExcessSwept(address indexed token, address indexed to, uint256 amount)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
]);

// Robin Among Thieves: the owner, keeper and round-health events the watcher reads (M-4), and the keeper's calls (M-5).
export const ratAbi = parseAbi([
  "function keeper() view returns (address)",
  "function entriesPaused() view returns (bool)",
  "function pairingLapses() view returns (uint256)",
  "function commitSeedChain(bytes32 tip, uint64 fromRound)",
  "function revealSeed(uint256 roundId, bytes32 seed)",
  "function pair(uint256 roundId, uint256 maxSteps)",
  "function settle(uint256 roundId, uint256 maxMatches)",
  "function rounds(uint256) view returns (bytes32 entrantsAcc, bytes32 pairingSeed, uint32 entrants, uint32 houseEntrants, uint32 cursor, uint32 shuffled, uint32 matches, uint32 settled, uint32 eligible, uint32 bonusCursor, uint8 status, bool waiting, bool bonusFixed, uint64 seedL2Block, uint256 waitingId, uint128 bonusPerPlayer, uint128 paidTotal, bool seedMixed)",
  "event RoundCancelled(uint256 indexed roundId)",
  "event KeeperSet(address indexed keeper)",
  "event OpQueued(bytes32 indexed id, uint8 op, uint256 value, address addr, uint256 eta)",
  "event OpExecuted(bytes32 indexed id, uint8 op, uint256 value, address addr)",
  "event OpCancelled(bytes32 indexed id)",
  "event EntriesPaused(bool paused)",
  "event SeedChainCommitted(bytes32 tip, uint64 fromRound)",
  "event PairingLapsed(uint256 indexed roundId)",
  "event HouseSet(uint256 indexed agentId, bool house)",
  "event BondsQueued(bool enabled, uint128 minBond, uint256 eta)",
  "event BondsExecuted(bool enabled, uint128 minBond)",
  "event BondsCancelled()",
  "event ExcessSwept(address indexed token, address indexed to, uint256 amount)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
]);

// RakeBuyer: buys the buy token with RAT's rake (keeper `buy`), forwards it to the vault (or the timelocked forwardTo).
export const rakeBuyerAbi = parseAbi([
  "function keeper() view returns (address)",
  "function forwardTo() view returns (address)",
  "function buyPending() view returns (uint256)",
  "function legPending() view returns (uint256)",
  "function boughtOnDay(uint256) view returns (uint256)",
  "function usdg() view returns (address)",
  "function balanceOf(address) view returns (uint256)", // read on usdg(): RAT's rake lands without a sync()
  "function ratchetFloorRate() view returns (uint256)",
  "function buy(uint256 routeIdx, uint256 usdgIn, uint256 minOut) returns (uint256 out)",
  "function forwardToken(address token)",
  "event Bought(address indexed token, uint256 route, uint256 usdgIn, uint256 out, uint256 minOut)",
  "event KeeperSet(address indexed keeper)",
  "event RouteSet(uint256 indexed index, address route)",
  "event RatchetReset(uint256 newAnchor, uint64 epoch)",
  "event OpQueued(bytes32 indexed id, uint8 op, uint256 key, address value, uint256 eta)",
  "event OpExecuted(bytes32 indexed id, uint8 op, uint256 key, address value)",
  "event OpCancelled(bytes32 indexed id)",
  "event ExcessSwept(address indexed token, address indexed to, uint256 amount)",
  "event ForwardToSet(address to)",
  "event ForwardFailed(address indexed token, address indexed asset, address indexed to, uint256 amount)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
]);

// FeeSplitter (optional, not in Deploy.s.sol): a leg that failed its gas stipend is escrowed (A3-09).
export const feeSplitterAbi = parseAbi([
  "event LegEscrowed(address indexed token, address indexed to, uint256 amount)",
  "event ChangeQueued(bytes32 indexed id, uint8 op, uint256 key, address value, uint256 eta)",
  "event ChangeExecuted(bytes32 indexed id, uint8 op, uint256 key, address value)",
  "event ChangeCancelled(bytes32 indexed id)",
  "event RescueQueued(bytes32 indexed id, address indexed token, address indexed from, address to, uint256 amount, uint256 eta)",
  "event Rescued(address indexed token, address indexed from, address indexed to, uint256 amount)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
]);

// GameConfig: the play token, pass amount, buy token and split, changed only by the Safe through a 7-day timelock.
export const configAbi = parseAbi([
  "function tokens() view returns (address playToken, uint256 passLock, address buyToken)",
  "function epoch() view returns (uint64)",
  "event CoreBound(address core)",
  "event TokensQueued(uint64 nextEpoch, address playToken, uint256 passLock, address buyToken, uint256 eta)",
  "event TokensCancelled()",
  "event TokensExecuted(uint64 indexed epoch, address playToken, uint256 passLock, address buyToken)",
  "event SplitQueued((uint16 purseBps, uint16 almsBps, uint16 bonfireBps, uint16 tollBps, uint16 vBuyBps, uint16 vLiqBps, uint16 vBurnBps) s, uint256 eta)",
  "event SplitCancelled()",
  "event SplitExecuted((uint16 purseBps, uint16 almsBps, uint16 bonfireBps, uint16 tollBps, uint16 vBuyBps, uint16 vLiqBps, uint16 vBurnBps) s)",
  "event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)",
  "event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)",
]);

// Every buy route reports the token it delivers; FairCore refuses a route whose tokenOut isn't the buy token.
export const routeAbi = parseAbi(["function tokenOut() view returns (address)"]);

export const v4QuoterAbi = parseAbi([
  "function quoteExactInputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) returns (uint256 amountOut, uint256 gasEstimate)",
]);

export const testRouteAbi = parseAbi(["function RATE() view returns (uint256)"]);

// Errors the routes raise themselves (they bubble up through FairCore). The route's ShortFill() has no arguments and
// a different selector (0xd6971774) from FairCore's ShortFill(uint256,uint256) (0x1d868770); both mean "stall" here.
export const routeErrorsAbi = parseAbi([
  "error ShortFill()", "error OnlyCore()", "error NotPoolManager()", "error NotPool()", "error BadPool()", "error NotWeth()",
]);
// Matched by selector as well as by name, so an ABI change can't silently break stall detection.
export const SHORTFILL_SELECTORS = new Set(["0xd6971774", "0x1d868770"]);

// FairCore storage slots (forge inspect FairCore storageLayout; pinned by contracts/test/unit/WatcherSlots.t.sol, contracts/script/check_slots.sh checks it). The watcher's fill check zeroes these in a
// stateOverride so a fill right after the 50-minute gap, or at 00:00 UTC after a full day, can still be re-simulated
// at the block before (where the real state says TooSoon / DailyCap). Proven by the e2e "gap-boundary" step.
export const FAIRCORE_SLOTS = { lastSwapAt: 41n, swappedOnDay: 42n };

// Mainnet pools for route A quotes: USDG -> ETH on the Fables pool, then ETH -> the buy token on its own pool.
export const MAINNET = {
  usdg: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
  quoter: "0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94",
  usdgPool: {
    currency0: "0x0000000000000000000000000000000000000000",
    currency1: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    fee: 0x800000,
    tickSpacing: 10,
    hooks: "0x06a889870C8f83640D6816319f72e2aA579b6080",
  },
  // ETH -> buy token pool, keyed by the token's lowercase address. FairCore.buyToken() picks the entry; a buy token
  // with no entry here stops the keeper's buybacks and the watcher's price checks (fail closed) until one is added.
  quotePools: {
    "0x5173b8ea6923c2d40267890d45c46a3480954773": {
      currency0: "0x0000000000000000000000000000000000000000",
      currency1: "0x5173b8eA6923c2d40267890D45C46a3480954773",
      fee: 0,
      tickSpacing: 200,
      hooks: "0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044",
    },
  },
};

/** The ETH -> token quote pool for a buy token, or throws (the caller fails closed). */
export function quotePoolFor(token) {
  const p = MAINNET.quotePools[String(token).toLowerCase()];
  if (!p) throw new Error(`no quote pool for buy token ${token}: add it to MAINNET.quotePools`);
  return p;
}

// The only calls the keeper ever sends, computed from the ABI so they can't drift. The watcher rejects any keeper tx
// that isn't one of these, to one of the game contracts, with zero value.
export const KEEPER_SELECTORS = {
  burnBuyToken: toFunctionSelector("function burnBuyToken(uint8,uint256,uint256,uint256)"),
  buyForVault: toFunctionSelector("function buyForVault(uint256,uint256,uint256)"),
  settle: toFunctionSelector("function settle(uint256)"), // LastArrow and SheriffsSeat
  finalize: toFunctionSelector("function finalize(uint256)"),
  releaseAlms: toFunctionSelector("function releaseAlms(uint256)"),
  // M-5: the same keeper key runs Robin Among Thieves and RakeBuyer
  commitSeedChain: toFunctionSelector("function commitSeedChain(bytes32,uint64)"),
  revealSeed: toFunctionSelector("function revealSeed(uint256,bytes32)"),
  pair: toFunctionSelector("function pair(uint256,uint256)"),
  ratSettle: toFunctionSelector("function settle(uint256,uint256)"),
  rakeBuy: toFunctionSelector("function buy(uint256,uint256,uint256)"),
  forwardToken: toFunctionSelector("function forwardToken(address)"),
};
