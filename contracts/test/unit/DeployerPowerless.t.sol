// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IFairCore, IGameConfig, Tokens, Split} from "../../src/interfaces/IFair.sol";
import {IIdentityRegistry, IReputationRegistry} from "../../src/interfaces/I8004.sol";
import {GameConfig} from "../../src/GameConfig.sol";
import {FairPass} from "../../src/FairPass.sol";
import {FairCore} from "../../src/FairCore.sol";
import {AlmsVote} from "../../src/AlmsVote.sol";
import {LocksleyVault, ICoreVaultUsdg} from "../../src/LocksleyVault.sol";
import {RobinAmongThieves} from "../../src/RobinAmongThieves.sol";
import {RakeBuyer} from "../../src/RakeBuyer.sol";
import {MockToken} from "../mocks/Mocks.sol";
import {AcceptBase} from "../../script/SafeAccept.s.sol";
import {DeployBase} from "../../script/Deploy.s.sol";

/// Exposes SafeAcceptVerify's post-accept check. The deployer must hold no owner, pending owner or other role.
contract DeployerPowerHarness is AcceptBase {
    function check(D memory d, address deployer, address safe_, address[] memory safeOwners) external view {
        _assertDeployerHasNoPower(d, deployer, safe_, safeOwners);
    }

    function passLock() external pure returns (uint256) {
        return PASS_LOCK;
    }

    /// The same check SafeAcceptVerify runs on GameConfig's play token, lock and buy token.
    function assertLaunchTokens(address play, uint256 lockAmt, address buy, address wif) external pure {
        _requireLaunchTokens(play, lockAmt, buy, wif);
    }
}

/// Exposes the mainnet deploy's pre-broadcast check (fresh EOA at nonce 0, not a signer, no USDG or $wif).
contract FreshDeployerHarness is DeployBase {
    function check(
        address deployer,
        address safe_,
        address keeper,
        address toll,
        address[] memory safeOwners,
        address usdg,
        address wif
    ) external view {
        _requireFreshDeployer(deployer, safe_, keeper, toll, safeOwners, usdg, wif);
    }

    function passLock() external pure returns (uint256) {
        return PASS_LOCK;
    }

    /// The same check the deploy runs on GameConfig's play token, lock and buy token.
    function assertLaunchTokens(address play, uint256 lockAmt, address buy, address wif) external pure {
        _requireLaunchTokens(play, lockAmt, buy, wif);
    }
}

contract FreshDeployerTest is Test {
    FreshDeployerHarness h;
    MockToken usdg;
    MockToken wif;
    address deployer = makeAddr("deployer");
    address safe_ = makeAddr("safe");
    address keeper = makeAddr("keeper");
    address toll = makeAddr("toll");

    function setUp() public {
        h = new FreshDeployerHarness();
        vm.allowCheatcodes(address(h));
        usdg = new MockToken("Global Dollar", "USDG", 6);
        wif = new MockToken("World is Flat", "WIF", 18);
    }

    function _owners() internal returns (address[] memory o) {
        o = new address[](3);
        o[0] = makeAddr("signer1");
        o[1] = makeAddr("signer2");
        o[2] = makeAddr("signer3");
    }

    function test_freshEoa_passes() public {
        h.check(deployer, safe_, keeper, toll, _owners(), address(usdg), address(wif));
    }

    function test_zeroDeployer_refused() public {
        vm.expectRevert(bytes("deployer missing"));
        h.check(address(0), safe_, keeper, toll, _owners(), address(usdg), address(wif));
    }

    function test_contractDeployer_refused() public {
        vm.expectRevert(bytes("deployer must be an EOA"));
        h.check(address(this), safe_, keeper, toll, _owners(), address(usdg), address(wif));
    }

    function test_deployerIsTheSafe_refused() public {
        vm.expectRevert(bytes("deployer is the Safe"));
        h.check(safe_, safe_, keeper, toll, _owners(), address(usdg), address(wif));
    }

    function test_deployerIsKeeper_refused() public {
        vm.expectRevert(bytes("deployer is the keeper"));
        h.check(deployer, safe_, deployer, toll, _owners(), address(usdg), address(wif));
    }

    function test_deployerIsToll_refused() public {
        vm.expectRevert(bytes("deployer is the toll recipient"));
        h.check(deployer, safe_, keeper, deployer, _owners(), address(usdg), address(wif));
    }

    function test_deployerIsSafeSigner_refused() public {
        address[] memory o = _owners();
        o[2] = deployer;
        vm.expectRevert(bytes("deployer is a Safe signer"));
        h.check(deployer, safe_, keeper, toll, o, address(usdg), address(wif));
    }

    /// L-5: dust sent to the deployer warns, it doesn't block the deploy.
    function test_deployerHoldsUsdg_warnsOnly() public {
        usdg.mint(deployer, 1);
        h.check(deployer, safe_, keeper, toll, _owners(), address(usdg), address(wif));
    }

    /// Deploy writes PASS_LOCK; SafeAcceptVerify accepts that amount and refuses the old 10,000 $wif lock.
    function test_deployAndSafeAcceptVerify_agreeOn5k() public {
        FreshDeployerHarness deploy = new FreshDeployerHarness();
        DeployerPowerHarness verify = new DeployerPowerHarness();
        assertEq(deploy.passLock(), 5_000e18, "deploy launch lock");
        assertEq(verify.passLock(), 5_000e18, "verify launch lock");
        assertEq(deploy.passLock(), verify.passLock(), "deploy and verify share the lock");

        address wifToken = makeAddr("wif");
        deploy.assertLaunchTokens(wifToken, 5_000e18, wifToken, wifToken);
        verify.assertLaunchTokens(wifToken, 5_000e18, wifToken, wifToken);
        vm.expectRevert(bytes("config tokens"));
        verify.assertLaunchTokens(wifToken, 10_000e18, wifToken, wifToken);
    }

    function test_deployerHoldsWif_warnsOnly() public {
        wif.mint(deployer, 1);
        h.check(deployer, safe_, keeper, toll, _owners(), address(usdg), address(wif));
    }

    function test_deployerNonceNotZero_refused() public {
        vm.setNonce(deployer, 1);
        vm.expectRevert(bytes("deployer nonce isn't 0"));
        h.check(deployer, safe_, keeper, toll, _owners(), address(usdg), address(wif));
    }
}

/// Post-accept: every owner, pending owner and named role the contracts expose, plus Safe signers and token balances.
contract DeployerPowerlessTest is Test {
    uint256 constant T0 = 1_800_000_000;

    DeployerPowerHarness h;
    address deployer = makeAddr("deployer");
    address safe_ = makeAddr("safe");
    address keeper = makeAddr("keeper");
    address toll = makeAddr("toll");

    MockToken usdg;
    MockToken wif;
    GameConfig config;
    FairPass pass;
    FairCore core;
    AlmsVote alms;
    LocksleyVault vault;
    RobinAmongThieves rat;
    RakeBuyer rakeBuyer;

    struct Roles {
        address fcKeeper;
        address tollTo;
        address almsTo;
        address robinKeeper;
        address rakeKeeper;
        address rakeSink;
        address houseSink;
        bool asBooth;
        bool asBuyRoute;
        bool asRakeRoute;
        bool almsVoteIsDeployer;
        bool vaultIsDeployer;
        bool queueLauncher;
        bool attachLauncher;
        bool skipConfigAccept;
        bool skipPassAccept;
    }

    function setUp() public {
        h = new DeployerPowerHarness();
        vm.warp(T0);
    }

    function _owners() internal returns (address[] memory o) {
        o = new address[](3);
        o[0] = makeAddr("signer1");
        o[1] = makeAddr("signer2");
        o[2] = makeAddr("signer3");
    }

    function _split() internal pure returns (Split memory) {
        return Split({
            purseBps: 6000, almsBps: 2000, bonfireBps: 1750, tollBps: 1750, vBuyBps: 2500, vLiqBps: 2500, vBurnBps: 2500
        });
    }

    function _happy() internal {
        Roles memory r;
        _deploy(r);
    }

    function _deploy(Roles memory r) internal {
        usdg = new MockToken("Global Dollar", "USDG", 6);
        wif = new MockToken("World is Flat", "WIF", 18);
        config =
            new GameConfig(deployer, address(usdg), 7 days, Tokens(address(wif), 5_000e18, address(wif)), _split());
        pass = new FairPass(IGameConfig(address(config)), deployer);
        core = new FairCore(IERC20(address(usdg)), IGameConfig(address(config)), pass, deployer, 48 hours);
        vm.prank(deployer);
        config.bindCore(address(core));
        alms = new AlmsVote(IFairCore(address(core)), deployer, 24 hours, 24 hours);
        vault = new LocksleyVault(ICoreVaultUsdg(address(core)), deployer);
        rakeBuyer = new RakeBuyer(IERC20(address(usdg)), IGameConfig(address(config)), address(vault), deployer, 0, address(core));
        rat = new RobinAmongThieves(
            RobinAmongThieves.Params({
                usdg: IERC20(address(usdg)),
                config: IGameConfig(address(config)),
                core: IFairCore(address(core)),
                identity: IIdentityRegistry(makeAddr("id")),
                reputation: IReputationRegistry(makeAddr("rep")),
                owner: deployer,
                timelockDelay: 0,
                bondDelay: 0,
                genesis: T0,
                keeper: r.robinKeeper == address(0) ? keeper : r.robinKeeper,
                rakeSink: r.rakeSink == address(0) ? address(rakeBuyer) : r.rakeSink,
                houseSink: r.houseSink == address(0) ? address(vault) : r.houseSink
            })
        );

        vm.startPrank(deployer);
        core.setupSet(FairCore.Op.SetKeeper, 0, r.fcKeeper == address(0) ? keeper : r.fcKeeper);
        core.setupSet(FairCore.Op.SetTollRecipient, 0, r.tollTo == address(0) ? toll : r.tollTo);
        core.setupSet(FairCore.Op.SetAlmsSafe, 0, r.almsTo == address(0) ? safe_ : r.almsTo);
        core.setupSet(FairCore.Op.SetAlmsVote, 0, r.almsVoteIsDeployer ? deployer : address(alms));
        core.setupSet(FairCore.Op.SetVault, 0, r.vaultIsDeployer ? deployer : address(vault));
        if (r.asBooth) core.setupSet(FairCore.Op.AddBooth, 0, deployer);
        if (r.asBuyRoute) core.setupSet(FairCore.Op.SetRoute, 0, deployer);
        rakeBuyer.setupSet(RakeBuyer.Op.SetKeeper, 0, r.rakeKeeper == address(0) ? keeper : r.rakeKeeper);
        if (r.asRakeRoute) rakeBuyer.setupSet(RakeBuyer.Op.SetRoute, 0, deployer);
        if (r.queueLauncher || r.attachLauncher) vault.queueLauncher(deployer);
        vm.stopPrank();

        if (r.attachLauncher) {
            vm.warp(T0 + 7 days);
            vm.prank(deployer);
            vault.attachLauncher();
        }
        if (!r.skipConfigAccept) _hand(config);
        _hand(core);
        if (!r.skipPassAccept) _hand(pass);
        _hand(alms);
        _hand(vault);
        _hand(rat);
        _hand(rakeBuyer);
    }

    function _hand(Ownable2Step c) internal {
        vm.prank(deployer);
        c.transferOwnership(safe_);
        vm.prank(safe_);
        c.acceptOwnership();
    }

    function _pack() internal view returns (DeployerPowerHarness.D memory d) {
        d.config = config;
        d.core = core;
        d.pass = pass;
        d.alms = alms;
        d.vault = vault;
        d.rat = rat;
        d.rakeBuyer = rakeBuyer;
        d.usdg = address(usdg);
        d.wif = address(wif);
        d.deployer = deployer;
    }

    function _check() internal {
        h.check(_pack(), deployer, safe_, _owners());
    }

    function test_afterAccept_deployerHasNoPower() public {
        _happy();
        _check();
    }

    function test_fileDeployerMismatch_refused() public {
        _happy();
        DeployerPowerHarness.D memory d = _pack();
        d.deployer = makeAddr("other");
        vm.expectRevert(bytes("DEPLOYER doesn't match the deployment file"));
        h.check(d, deployer, safe_, _owners());
    }

    function test_zeroDeployer_refused() public {
        _happy();
        vm.expectRevert(bytes("deployer missing from the deployment file"));
        h.check(_pack(), address(0), safe_, _owners());
    }

    function test_deployerIsTheSafe_refused() public {
        _happy();
        DeployerPowerHarness.D memory d = _pack();
        d.deployer = safe_;
        vm.expectRevert(bytes("deployer is the Safe"));
        h.check(d, safe_, safe_, _owners());
    }

    function test_deployerIsSafeSigner_refused() public {
        _happy();
        address[] memory o = _owners();
        o[0] = deployer;
        vm.expectRevert(bytes("deployer is a Safe signer"));
        h.check(_pack(), deployer, safe_, o);
    }

    function test_stillOwner_refused() public {
        Roles memory r;
        r.skipConfigAccept = true;
        _deploy(r);
        vm.expectRevert(bytes("GameConfig: deployer is still the owner"));
        _check();
    }

    function test_laterContractStillOwner_refused() public {
        Roles memory r;
        r.skipPassAccept = true;
        _deploy(r);
        vm.expectRevert(bytes("FairPass: deployer is still the owner"));
        _check();
    }

    function test_pendingOwner_refused() public {
        _happy();
        vm.prank(safe_);
        config.transferOwnership(deployer);
        vm.expectRevert(bytes("GameConfig: deployer is the pending owner"));
        _check();
    }

    function test_fairCoreKeeper_refused() public {
        Roles memory r;
        r.fcKeeper = deployer;
        _deploy(r);
        vm.expectRevert(bytes("deployer is the FairCore keeper"));
        _check();
    }

    function test_robinKeeper_refused() public {
        Roles memory r;
        r.robinKeeper = deployer;
        _deploy(r);
        vm.expectRevert(bytes("deployer is the Robin keeper"));
        _check();
    }

    function test_rakeKeeper_refused() public {
        Roles memory r;
        r.rakeKeeper = deployer;
        _deploy(r);
        vm.expectRevert(bytes("deployer is the RakeBuyer keeper"));
        _check();
    }

    function test_tollRecipient_refused() public {
        Roles memory r;
        r.tollTo = deployer;
        _deploy(r);
        vm.expectRevert(bytes("deployer is the toll recipient"));
        _check();
    }

    function test_almsSafe_refused() public {
        Roles memory r;
        r.almsTo = deployer;
        _deploy(r);
        vm.expectRevert(bytes("deployer is the Alms Safe"));
        _check();
    }

    function test_almsVoteWiredToDeployer_refused() public {
        Roles memory r;
        r.almsVoteIsDeployer = true;
        _deploy(r);
        vm.expectRevert(bytes("deployer is wired as alms vote or vault"));
        _check();
    }

    function test_vaultWiredToDeployer_refused() public {
        Roles memory r;
        r.vaultIsDeployer = true;
        _deploy(r);
        vm.expectRevert(bytes("deployer is wired as alms vote or vault"));
        _check();
    }

    function test_booth_refused() public {
        Roles memory r;
        r.asBooth = true;
        _deploy(r);
        vm.expectRevert(bytes("deployer is a booth"));
        _check();
    }

    function test_buyRoute_refused() public {
        Roles memory r;
        r.asBuyRoute = true;
        _deploy(r);
        vm.expectRevert(bytes("deployer is a buy route"));
        _check();
    }

    function test_queuedLauncher_refused() public {
        Roles memory r;
        r.queueLauncher = true;
        _deploy(r);
        vm.expectRevert(bytes("deployer is the queued vault launcher"));
        _check();
    }

    function test_launcher_refused() public {
        Roles memory r;
        r.attachLauncher = true;
        _deploy(r);
        vm.expectRevert(bytes("deployer is the vault launcher"));
        _check();
    }

    function test_rakeSink_refused() public {
        Roles memory r;
        r.rakeSink = deployer;
        _deploy(r);
        vm.expectRevert(bytes("deployer is a Robin sink"));
        _check();
    }

    function test_houseSink_refused() public {
        Roles memory r;
        r.houseSink = deployer;
        _deploy(r);
        vm.expectRevert(bytes("deployer is a Robin sink"));
        _check();
    }

    function test_rakeRoute_refused() public {
        Roles memory r;
        r.asRakeRoute = true;
        _deploy(r);
        vm.expectRevert(bytes("deployer is a rake route"));
        _check();
    }

    /// L-5: dust sent to the deployer after the deploy warns, it doesn't block the verify.
    function test_holdsUsdg_warnsOnly() public {
        _happy();
        usdg.mint(deployer, 1);
        _check();
    }

    function test_holdsWif_warnsOnly() public {
        _happy();
        wif.mint(deployer, 1);
        _check();
    }
}
