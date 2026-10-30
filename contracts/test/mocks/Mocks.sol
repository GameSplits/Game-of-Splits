// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFairCore, IBuyRoute} from "../../src/interfaces/IFair.sol";

contract MockToken is ERC20 {
    uint8 private immutable dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        dec = d;
    }

    function decimals() public view override returns (uint8) {
        return dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Swaps USDG for its token at a fixed rate by minting. Rate is token wei per USDG unit (1e-6 USDG).
contract MockRoute is IBuyRoute {
    MockToken public immutable token;
    IERC20 public immutable usdg;
    uint256 public rate = 781_250e12; // 1 USDG -> 781.25 tokens ($wif = $0.00128)
    bool public shortchange;
    MockToken public payIn; // if set, mints this token instead of `token` (a route that pays the wrong token)

    constructor(MockToken t, IERC20 u) {
        token = t;
        usdg = u;
    }

    function tokenOut() external view returns (address) {
        return address(token);
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function setShortchange(bool s) external {
        shortchange = s;
    }

    function setPayIn(MockToken t) external {
        payIn = t;
    }

    function swapToToken(uint256 usdgIn, uint256, address recipient) external returns (uint256 out) {
        require(usdg.balanceOf(address(this)) >= usdgIn, "not funded");
        out = usdgIn * rate;
        if (shortchange) out /= 2; // ignores minOut on purpose; FairCore must catch it
        (address(payIn) == address(0) ? token : payIn).mint(recipient, out);
    }
}

/// @dev A minimal booth that forwards to FairCore, so FairCore can be tested on its own.
contract StubBooth {
    IFairCore public immutable core;

    constructor(IFairCore c) {
        core = c;
    }

    function shot(address player, uint256 key, uint256 gross) external {
        core.collect(msg.sender, player, key, gross);
    }

    function settle(uint256 key, address[] calldata w, uint256[] calldata a) external {
        core.award(key, w, a);
    }
}

/// @dev Etched at 0x64 so booths can read a controllable L2 block number and block hash.
contract MockArbSys {
    uint256 public n = 1_000_000;
    mapping(uint256 => bytes32) hashOf;
    mapping(uint256 => bool) hashForced;

    /// @dev Same revert ArbSys uses on Robinhood Chain mainnet (4663) and testnet (46630).
    error InvalidBlockNumber(uint256 requested, uint256 current);

    function set(uint256 v) external {
        n = v;
    }

    /// @notice Force the hash of one L2 block. An unforced block inside the last 256 gets a deterministic hash.
    function setHash(uint256 blockNum, bytes32 h) external {
        hashOf[blockNum] = h;
        hashForced[blockNum] = true;
    }

    function arbBlockNumber() external view returns (uint256) {
        return n;
    }

    /// @dev Current block, a future block, or a block older than 256 blocks reverts. Exactly 256 blocks back is kept.
    function arbBlockHash(uint256 blockNum) external view returns (bytes32) {
        if (blockNum >= n || n - blockNum > 256) revert InvalidBlockNumber(blockNum, n);
        if (hashForced[blockNum]) return hashOf[blockNum];
        return keccak256(abi.encode("arb-hash", blockNum));
    }
}

/// @dev Takes a 1% fee on every transfer: FairPass must refuse it (TransferMismatch).
contract FeeToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev A GameConfig stand-in that can be made to revert, to prove unlock never depends on it.
contract BreakableConfig {
    address public playToken;
    uint256 public passLock;
    bool public broken;

    constructor(address t, uint256 amt) {
        (playToken, passLock) = (t, amt);
    }

    function breakIt() external {
        broken = true;
    }

    function tokens() external view returns (address, uint256, address) {
        require(!broken, "config broken");
        return (playToken, passLock, playToken);
    }
}

// ---------------------------------------------------------------------------------------------------- ERC-8004 mocks


/// @dev The behaviour Robin Among Thieves relies on from the ERC-8004 Identity registry (v2.0.0): ids from 0, mint with
///      _safeMint to msg.sender, agentWallet = minter, cleared on every transfer; isAuthorizedOrOwner reverts for
///      unknown ids.
contract MockIdentity is ERC721 {
    uint256 public nextId;
    mapping(uint256 => address) internal wallet;

    constructor() ERC721("AgentIdentity", "AGENT") {}

    function register(string calldata) external returns (uint256 agentId) {
        agentId = nextId++;
        wallet[agentId] = msg.sender;
        _safeMint(msg.sender, agentId);
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return wallet[agentId];
    }

    function setAgentWallet(uint256 agentId, address w) external {
        require(_isAuthorized(ownerOf(agentId), msg.sender, agentId), "Not authorized");
        wallet[agentId] = w;
    }

    function isAuthorizedOrOwner(address spender, uint256 agentId) external view returns (bool) {
        return _isAuthorized(ownerOf(agentId), spender, agentId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) wallet[tokenId] = address(0);
        return super._update(to, tokenId, auth);
    }
}

/// @dev The ERC-8004 Reputation registry's checks (self-feedback revert, value bounds), plus a mode that makes every
///      write revert or burn all its gas.
contract MockReputation {
    MockIdentity public immutable identity;
    uint8 public mode; // 0 = normal, 1 = revert, 2 = burn all gas
    mapping(uint256 => mapping(address => uint64)) public count;
    mapping(uint256 => mapping(address => int256)) public sum;
    mapping(uint256 => string) public lastTag2;
    mapping(uint256 => int128) public lastValue;
    uint256 public writes;

    constructor(MockIdentity identity_) {
        identity = identity_;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata,
        string calldata,
        bytes32
    ) external {
        if (mode == 1) revert("registry down");
        if (mode == 2) {
            while (true) {} // burns every unit of gas it was given
        }
        require(valueDecimals <= 18, "too many decimals");
        require(!identity.isAuthorizedOrOwner(msg.sender, agentId), "Self-feedback not allowed");
        require(keccak256(bytes(tag1)) == keccak256("robinamongthieves"), "tag1");
        count[agentId][msg.sender]++;
        sum[agentId][msg.sender] += value;
        lastTag2[agentId] = tag2;
        lastValue[agentId] = value;
        writes++;
    }
}
