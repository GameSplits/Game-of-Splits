// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBuyRoute} from "../interfaces/IFair.sol";

/// @title TestToken (TESTNET ONLY)
/// @notice Stand-ins for USDG (6 dp) and 18-dp game tokens on Robinhood Chain testnet.
///         Anyone can mint a capped amount once an hour from the site's faucet button. Refuses to deploy on mainnet.
contract TestToken is ERC20 {
    uint8 private immutable dec;
    uint256 public immutable faucetAmount;
    address public immutable minter; // the testnet route, which mints this token to simulate a swap
    mapping(address => uint256) public lastFaucet;

    error NotOnMainnet();
    error TooSoon();
    error NotMinter();

    constructor(string memory n, string memory s, uint8 d, uint256 faucetAmount_, address minter_) ERC20(n, s) {
        if (block.chainid == 4663) revert NotOnMainnet();
        dec = d;
        faucetAmount = faucetAmount_;
        minter = minter_;
    }

    function decimals() public view override returns (uint8) {
        return dec;
    }

    function faucet() external {
        if (block.timestamp < lastFaucet[msg.sender] + 1 hours) revert TooSoon();
        lastFaucet[msg.sender] = block.timestamp;
        _mint(msg.sender, faucetAmount);
    }

    function mintTo(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
}

interface ITestMint {
    function mintTo(address to, uint256 amount) external;
}

/// @title TestRoute (TESTNET ONLY)
/// @notice Simulates the buyback swap on testnet: keeps the USDG and mints its test token at a fixed rate (the tWIF route
///         uses 781.25 per USDG, i.e. $wif at $0.00128). Refuses to deploy on mainnet.
contract TestRoute is IBuyRoute {
    address public core;
    address public extraCaller; // a second contract allowed to swap (testnet RakeBuyer)
    ITestMint public token;
    address public immutable deployer;
    uint256 public immutable RATE; // test-token wei per USDG unit

    error NotOnMainnet();
    error OnlyCore();
    error Once();

    constructor(uint256 rate_) {
        if (block.chainid == 4663) revert NotOnMainnet();
        deployer = msg.sender;
        RATE = rate_;
    }

    /// @dev Wired once after FairCore and the test token exist (they depend on each other through this route).
    function wire(address core_, ITestMint token_) external {
        if (msg.sender != deployer || core != address(0)) revert Once();
        (core, token) = (core_, token_);
    }

    /// @dev Once, by the deployer: let one more contract (the testnet RakeBuyer) use this route.
    function wireExtra(address caller) external {
        if (msg.sender != deployer || extraCaller != address(0)) revert Once();
        extraCaller = caller;
    }

    function tokenOut() external view returns (address) {
        return address(token);
    }

    function swapToToken(uint256 usdgIn, uint256, address recipient) external returns (uint256 out) {
        if (msg.sender != core && (msg.sender != extraCaller || extraCaller == address(0))) revert OnlyCore();
        out = usdgIn * RATE;
        token.mintTo(recipient, out);
    }
}
