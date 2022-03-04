// SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.11;

import "ds-test/test.sol";
import "forge-std/Vm.sol";
import "forge-std/stdlib.sol";
import "./utils/ERC20Utils.sol";

import "../../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../../interfaces/badger/ISettV4h.sol";

import "../StrategySolidexStaker.sol";
import "../deps/Controller.sol";
import "../deps/SettV4.sol";

contract Config {
    IERC20Upgradeable public constant WANT =
        IERC20Upgradeable(0xC0240Ee4405f11EFb87A00B432A8be7b7Afc97CC);

    ISettV4h public constant BSOLID_SOLIDSEX =
        ISettV4h(0xC7cBF5a24caBA375C09cc824481F5508c644dF28);
    ISettV4h public constant BSEX_WFTM =
        ISettV4h(0x7cc6049a125388B51c530e51727A87aE101f6417);

    uint256 public constant MAX_BPS = 10_000;

    uint256 public constant PERFORMANCE_FEE_GOVERNANCE = 1500;
    uint256 public constant PERFORMANCE_FEE_STRATEGIST = 0;
    uint256 public constant WITHDRAWAL_FEE = 10;

    address public constant BADGER_REGISTRY =
        0xFda7eB6f8b7a9e9fCFd348042ae675d1d652454f;

    address public constant BADGER_DEV_MULTISIG =
        0x4c56ee3295042f8A5dfC83e770a21c707CB46f5b;
    address public constant BADGER_TREE =
        0x89122c767A5F543e663DB536b603123225bc3823;
}

contract StrategySolidexStakerTest is DSTest, stdCheats, Config, SnapshotManager {
    using SafeMathUpgradeable for uint256;

    // ==============
    // ===== Vm =====
    // ==============

    Vm constant vm = Vm(HEVM_ADDRESS);
    ERC20Utils immutable erc20utils = new ERC20Utils();

    // =====================
    // ===== Constants =====
    // =====================

    address constant governance =
        address(uint160(uint256(keccak256("governance"))));
    address constant strategist =
        address(uint160(uint256(keccak256("strategist"))));
    address constant guardian =
        address(uint160(uint256(keccak256("guardian"))));
    address constant keeper = address(uint160(uint256(keccak256("keeper"))));
    address constant treasury =
        address(uint160(uint256(keccak256("treasury"))));

    address constant rando = address(uint160(uint256(keccak256("rando"))));

    // =================
    // ===== State =====
    // =================

    Controller controller = new Controller();
    SettV4 sett = new SettV4();
    StrategySolidexStaker strategy = new StrategySolidexStaker();

    // ==================
    // ===== Events =====
    // ==================

    event Harvest(uint256 harvested, uint256 indexed blockNumber);

    event TreeDistribution(
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    event PerformanceFeeGovernance(
        address indexed destination,
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );
    event PerformanceFeeStrategist(
        address indexed destination,
        address indexed token,
        uint256 amount,
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    // ==================
    // ===== Set up =====
    // ==================

    function setUp() public {
        controller.initialize(governance, strategist, keeper, treasury);

        sett.initialize(
            address(WANT),
            address(controller),
            governance,
            keeper,
            guardian,
            false,
            "",
            ""
        );

        strategy.initialize(
            governance,
            strategist,
            address(controller),
            keeper,
            guardian,
            address(WANT),
            [
                PERFORMANCE_FEE_GOVERNANCE,
                PERFORMANCE_FEE_STRATEGIST,
                WITHDRAWAL_FEE
            ]
        );

        vm.startPrank(governance);
        sett.unpause();
        controller.setVault(address(WANT), address(sett));

        controller.approveStrategy(address(WANT), address(strategy));
        controller.setStrategy(address(WANT), address(strategy));

        vm.stopPrank();

        // TODO: No magic var
        erc20utils.forceMint(address(WANT), 10e18);
    }

    // ======================
    // ===== Unit Tests =====
    // ======================

    function testFeeConfig() public {
        assertEq(
            strategy.performanceFeeGovernance(),
            PERFORMANCE_FEE_GOVERNANCE
        );
        assertEq(
            strategy.performanceFeeStrategist(),
            PERFORMANCE_FEE_STRATEGIST
        );
        assertEq(strategy.withdrawalFee(), WITHDRAWAL_FEE);
    }

    function testProtectedTokens() public {
        address[] memory protectedTokens = strategy.getProtectedTokens();

        assertEq(protectedTokens.length, 5);

        assertEq(protectedTokens[0], address(WANT));
        assertEq(protectedTokens[1], address(strategy.solid()));
        assertEq(protectedTokens[2], address(strategy.solidSex()));
        assertEq(protectedTokens[3], address(strategy.sex()));
        assertEq(protectedTokens[4], address(strategy.wftm()));
    }

    function testAreYouTrying() public {
        startingBalance = want.balanceOf(deployer);
        depositAmount = startingBalance.div(2);

        depositChecked(depositAmount);

        available = sett.available();
        assertGt(available, 0);

        sett.earn();

        vm.roll(10000 * 13);

        assertEq(want.balanceOf(sett), depositAmount - available);

        assertLt(want.balanceOf(strategy), available);

        assertEq(want.balanceOf(strategy), 0);

        vm.expectEmit(true, false, false, true);
        emit Harvest(0, block.number);

        harvest = strategy.harvest();
    }

    /*
    function testPerformanceFees() public {
        startingBalance = want.balanceOf(deployer);
        depositAmount = startingBalance.div(2);

        sett.deposit(depositAmount);

        available = sett.available();
        assertGt(available, 0);

        sett.earn();

        vm.roll(1 days);

        assertEq(want.balanceOf(sett), depositAmount - available);

        assertLt(want.balanceOf(strategy), available);

        assertEq(want.balanceOf(strategy), 0);

        harvest = strategy.harvest();
    }

    function stateSetup() public { 
        startingBalance = want.balanceOf(deployer);

        depositAmount = startingBalance.mul(8).div(10);

        want.approve(sett, type(uint256).max);
        sett.deposit(depositAmount);

        vm.roll(1 days);

        vm.prank(keeper);
        sett.earn();

        vm.roll(1 days);

        if (strategy.isTendable()) {
            strategy.tend()
        }

        vm.prank(keeper);
        strategy.harvest();

        vm.roll(1 days);
    }


    function testStrategyActionPermissions() public {
        state_setup(deployer, sett, controller, strategy, want)

        tendable = strategy.isTendable()

        authorizedActors = [
            strategy.governance(),
            strategy.keeper(),
        ]

        vm.expectRevert("onlyAuthorizedActorsOrController");
        strategy.deposit();

        for actor in authorizedActors:
            strategy.deposit({"from": actor})

        for actor in authorizedActors:
            chain.sleep(10000 * 13)
            strategy.harvest({"from": actor})

        vm.expectRevert("onlyAuthorizedActors");
        strategy.harvest();

        if tendable:
            with brownie.reverts("onlyAuthorizedActors"):
                strategy.tend({"from": randomUser})

            for actor in authorizedActors:
                strategy.tend({"from": actor})

        actorsToCheck = [
            randomUser,
            strategy.governance(),
            strategy.strategist(),
            strategy.keeper(),
        ]

        # withdrawAll onlyController
        for actor in actorsToCheck:
            with brownie.reverts("onlyController"):
                strategy.withdrawAll({"from": actor})

        # withdraw onlyController
        for actor in actorsToCheck:
            with brownie.reverts("onlyController"):
                strategy.withdraw(1, {"from": actor})

        # withdrawOther _onlyNotProtectedTokens
        for actor in actorsToCheck:
            with brownie.reverts("onlyController"):
                strategy.withdrawOther(controller, {"from": actor})
    }


    function testStrategyConfigPermissions() public {
        randomUser = accounts[6]

        randomUser = accounts[8]
        # End Setup

        governance = strategy.governance()

        # Valid User should update
        strategy.setGuardian(AddressZero, {"from": governance})
        assert strategy.guardian() == AddressZero

        strategy.setWithdrawalFee(0, {"from": governance})
        assert strategy.withdrawalFee() == 0

        strategy.setPerformanceFeeStrategist(0, {"from": governance})
        assert strategy.performanceFeeStrategist() == 0

        strategy.setPerformanceFeeGovernance(0, {"from": governance})
        assert strategy.performanceFeeGovernance() == 0

        strategy.setController(AddressZero, {"from": governance})
        assert strategy.controller() == AddressZero

        # Invalid User should fail
        with brownie.reverts("onlyGovernance"):
            strategy.setGuardian(AddressZero, {"from": randomUser})

        with brownie.reverts("onlyGovernance"):
            strategy.setWithdrawalFee(0, {"from": randomUser})

        with brownie.reverts("onlyGovernance"):
            strategy.setPerformanceFeeStrategist(0, {"from": randomUser})

        with brownie.reverts("onlyGovernance"):
            strategy.setPerformanceFeeGovernance(0, {"from": randomUser})

        with brownie.reverts("onlyGovernance"):
            strategy.setController(AddressZero, {"from": randomUser})

        # Harvest:
        strategy.setPerformanceFeeGovernance(0, {"from": governance})
        assert strategy.performanceFeeGovernance() == 0

        strategy.setPerformanceFeeStrategist(0, {"from": governance})
        assert strategy.performanceFeeStrategist() == 0

        with brownie.reverts("onlyGovernance"):
            strategy.setPerformanceFeeGovernance(0, {"from": randomUser})

        with brownie.reverts("onlyGovernance"):
            strategy.setPerformanceFeeStrategist(0, {"from": randomUser})
    }

    function testStrategyConfigPermissions() public {
        vm.expectRevert("onlyGovernance");
        strategy.setGuardian(address(0));

        vm.expectRevert("onlyGovernance");
        strategy.setWithdrawalFee(0);

        vm.expectRevert("onlyGovernance");
        strategy.setPerformanceFeeStrategist(0);

        vm.expectRevert("onlyGovernance");
        strategy.setPerformanceFeeGovernance(0);

        vm.expectRevert("onlyGovernance");
        strategy.setController(address(0));

        vm.expectRevert("onlyGovernance");
        strategy.setPerformanceFeeGovernance(0);

        vm.expectRevert("onlyGovernance");
        strategy.setPerformanceFeeStrategist(0);

        strategy.setPerformanceFeeGovernance(0, {"from": governance})
        assert strategy.performanceFeeGovernance() == 0

        strategy.setPerformanceFeeStrategist(0, {"from": governance})
        assert strategy.performanceFeeStrategist() == 0

    }


    function testStrategyPausingPermissions() public {
        state_setup(deployer, sett, controller, strategy, want)

        authorizedPausers = [
            strategy.governance(),
            strategy.guardian(),
        ]

        authorizedUnpausers = [
            strategy.governance(),
        ]

        vm.expectRevert("onlyPausers"):
        strategy.pause();

        vm.expectRevert("onlyGovernance"):
        strategy.unpause();

        vm.prank(guardian);
        strategy.pause()

        vm.expectRevert("Pausable: paused"):
        sett.withdrawAll();

        vm.expectRevert("Pausable: paused"):
        strategy.harvest();

        if (strategy.isTendable()) {
            vm.expectRevert("Pausable: paused"):
            strategy.tend();
        }

        strategy.unpause({"from": authorizedUnpausers[0]})

        for pauser in authorizedPausers:
            strategy.pause({"from": pauser})
            strategy.unpause({"from": authorizedUnpausers[0]})

        for unpauser in authorizedUnpausers:
            strategy.pause({"from": unpauser})
            strategy.unpause({"from": unpauser})

        sett.deposit(1, {"from": deployer})
        sett.withdraw(1, {"from": deployer})
        sett.withdrawAll({"from": deployer})

        strategy.harvest({"from": strategyKeeper})
        if strategy.isTendable():
            strategy.tend({"from": strategyKeeper})
    }


    function testSettPausingPermissions() public {
        # Setup
        state_setup(deployer, sett, controller, strategy, want)
        randomUser = accounts[8]
        # End Setup

        assert sett.strategist() == AddressZero
        # End Setup

        authorizedPausers = [
            sett.governance(),
            sett.guardian(),
        ]

        authorizedUnpausers = [
            sett.governance(),
        ]

        # pause onlyPausers
        for pauser in authorizedPausers:
            sett.pause({"from": pauser})
            sett.unpause({"from": authorizedUnpausers[0]})

        with brownie.reverts("onlyPausers"):
            sett.pause({"from": randomUser})

        # unpause onlyPausers
        for unpauser in authorizedUnpausers:
            sett.pause({"from": unpauser})
            sett.unpause({"from": unpauser})

        sett.pause({"from": sett.guardian()})
        with brownie.reverts("onlyGovernance"):
            sett.unpause({"from": randomUser})

        settKeeper = accounts.at(sett.keeper(), force=True)

        with brownie.reverts("Pausable: paused"):
            sett.earn({"from": settKeeper})
        with brownie.reverts("Pausable: paused"):
            sett.withdrawAll({"from": deployer})
        with brownie.reverts("Pausable: paused"):
            sett.withdraw(1, {"from": deployer})
        with brownie.reverts("Pausable: paused"):
            sett.deposit(1, {"from": randomUser})
        with brownie.reverts("Pausable: paused"):
            sett.depositAll({"from": randomUser})

        sett.unpause({"from": authorizedUnpausers[0]})

        sett.deposit(1, {"from": deployer})
        sett.earn({"from": settKeeper})
        sett.withdraw(1, {"from": deployer})
        sett.withdrawAll({"from": deployer})
    }


    function testSettConfigPermissions() public {
        state_setup(deployer, sett, controller, strategy, want)
        randomUser = accounts[8]
        assert sett.strategist() == AddressZero
        # End Setup

        # == Governance ==
        validActor = sett.governance()

        # setMin
        with brownie.reverts("onlyGovernance"):
            sett.setMin(0, {"from": randomUser})

        sett.setMin(0, {"from": validActor})
        assert sett.min() == 0

        # setController
        with brownie.reverts("onlyGovernance"):
            sett.setController(AddressZero, {"from": randomUser})

        sett.setController(AddressZero, {"from": validActor})
        assert sett.controller() == AddressZero

        # setStrategist
        with brownie.reverts("onlyGovernance"):
            sett.setStrategist(validActor, {"from": randomUser})

        sett.setStrategist(validActor, {"from": validActor})
        assert sett.strategist() == validActor

        with brownie.reverts("onlyGovernance"):
            sett.setKeeper(validActor, {"from": randomUser})

        sett.setKeeper(validActor, {"from": validActor})
        assert sett.keeper() == validActor
    }


    function testSettEarnPermissions() public {
        # Setup
        state_setup(deployer, sett, controller, strategy, want)
        randomUser = accounts[8]
        assert sett.strategist() == AddressZero
        # End Setup

        # == Authorized Actors ==
        # earn

        authorizedActors = [
            sett.governance(),
            sett.keeper(),
        ]

        with brownie.reverts("onlyAuthorizedActors"):
            sett.earn({"from": randomUser})

        for actor in authorizedActors:
            chain.snapshot()
            sett.earn({"from": actor})
            chain.revert()
    }


    /// ===========================
    /// ===== Lifecycle Tests =====
    /// ===========================

    MAX_BASIS = 10000

    function testIsProfitable() public {
        deployer = deployed.deployer
        vault = deployed.vault
        controller = deployed.controller
        strategy = deployed.strategy
        want = deployed.want
        randomUser = accounts[6]

        initial_balance = want.balanceOf(deployer)

        settKeeper = accounts.at(vault.keeper(), force=True)

        snap = SnapshotManager(vault, strategy, controller, "StrategySnapshot")

        # Deposit
        assert want.balanceOf(deployer) > 0

        depositAmount = int(want.balanceOf(deployer) * 0.8)
        assert depositAmount > 0

        want.approve(vault.address, MaxUint256, {"from": deployer})

        snap.settDeposit(depositAmount, {"from": deployer})

        # Earn
        with brownie.reverts("onlyAuthorizedActors"):
            vault.earn({"from": randomUser})

        min = vault.min()
        max = vault.max()
        remain = max - min

        snap.settEarn({"from": settKeeper})

        chain.sleep(15)
        chain.mine(1)

        snap.settWithdrawAll({"from": deployer})

        ending_balance = want.balanceOf(deployer)

        initial_balance_with_fees = initial_balance * (
            1 - (DEFAULT_WITHDRAWAL_FEE / MAX_BASIS)
        )

        print("Initial Balance")
        print(initial_balance)
        print("initial_balance_with_fees")
        print(initial_balance_with_fees)
        print("Ending Balance")
        print(ending_balance)

        assert ending_balance > initial_balance_with_fees
    }


    function testDepositWithdrawSingleUserFlow() public {
        # Setup
        snap = SnapshotManager(vault, strategy, controller, "StrategySnapshot")
        randomUser = accounts[6]
        # End Setup

        # Deposit
        assert want.balanceOf(deployer) > 0

        depositAmount = int(want.balanceOf(deployer) * 0.8)
        assert depositAmount > 0

        want.approve(vault.address, MaxUint256, {"from": deployer})

        snap.settDeposit(depositAmount, {"from": deployer})

        shares = vault.balanceOf(deployer)

        # Earn
        with brownie.reverts("onlyAuthorizedActors"):
            vault.earn({"from": randomUser})

        snap.settEarn({"from": settKeeper})

        chain.sleep(15)
        chain.mine(1)

        snap.settWithdraw(shares // 2, {"from": deployer})

        chain.sleep(10000)
        chain.mine(1)

        snap.settWithdraw(shares // 2 - 1, {"from": deployer})
    }


    function testSingleUserHarvestFlow() public {
        # Setup
        snap = SnapshotManager(vault, strategy, controller, "StrategySnapshot")
        randomUser = accounts[6]
        tendable = strategy.isTendable()
        startingBalance = want.balanceOf(deployer)
        depositAmount = startingBalance // 2
        assert startingBalance >= depositAmount
        assert startingBalance >= 0
        # End Setup

        # Deposit
        want.approve(sett, MaxUint256, {"from": deployer})
        snap.settDeposit(depositAmount, {"from": deployer})
        shares = vault.balanceOf(deployer)

        assert want.balanceOf(sett) > 0
        print("want.balanceOf(sett)", want.balanceOf(sett))

        # Earn
        snap.settEarn({"from": settKeeper})

        if tendable:
            with brownie.reverts("onlyAuthorizedActors"):
                strategy.tend({"from": randomUser})

            snap.settTend({"from": strategyKeeper})

        chain.sleep(days(0.5))
        chain.mine()

        if tendable:
            snap.settTend({"from": strategyKeeper})

        chain.sleep(days(14))
        voter.distribute({'from': deployer})

        with brownie.reverts("onlyAuthorizedActors"):
            strategy.harvest({"from": randomUser})

        snap.settHarvest({"from": strategyKeeper})

        chain.sleep(days(1))
        chain.mine()

        if tendable:
            snap.settTend({"from": strategyKeeper})

        snap.settWithdraw(shares // 2, {"from": deployer})

        chain.sleep(days(3))
        chain.mine()

        snap.settHarvest({"from": strategyKeeper})
        snap.settWithdraw(shares // 2 - 1, {"from": deployer})
    }


    function testMigrateSingleUser() public {
        # Setup
        randomUser = accounts[6]
        snap = SnapshotManager(vault, strategy, controller, "StrategySnapshot")

        startingBalance = want.balanceOf(deployer)
        depositAmount = startingBalance // 2
        assert startingBalance >= depositAmount
        # End Setup

        # Deposit
        want.approve(sett, MaxUint256, {"from": deployer})
        snap.settDeposit(depositAmount, {"from": deployer})

        chain.sleep(15)
        chain.mine()

        sett.earn({"from": strategist})

        chain.snapshot()

        # Test no harvests
        chain.sleep(days(2))
        chain.mine()

        before = {"settWant": want.balanceOf(sett), "stratWant": strategy.balanceOf()}

        with brownie.reverts():
            controller.withdrawAll(strategy.want(), {"from": randomUser})

        controller.withdrawAll(strategy.want(), {"from": deployer})

        after = {"settWant": want.balanceOf(sett), "stratWant": strategy.balanceOf()}

        assert after["settWant"] > before["settWant"]
        assert after["stratWant"] < before["stratWant"]
        assert after["stratWant"] == 0

        # Test tend only
        if strategy.isTendable():
            chain.revert()

            chain.sleep(days(2))
            chain.mine()

            strategy.tend({"from": deployer})

            before = {"settWant": want.balanceOf(sett), "stratWant": strategy.balanceOf()}

            with brownie.reverts():
                controller.withdrawAll(strategy.want(), {"from": randomUser})

            controller.withdrawAll(strategy.want(), {"from": deployer})

            after = {"settWant": want.balanceOf(sett), "stratWant": strategy.balanceOf()}

            assert after["settWant"] > before["settWant"]
            assert after["stratWant"] < before["stratWant"]
            assert after["stratWant"] == 0

        # Test harvest, with tend if tendable
        chain.revert()

        chain.sleep(days(1))
        chain.mine()

        if strategy.isTendable():
            strategy.tend({"from": deployer})

        chain.sleep(days(1))
        chain.mine()

        before = {
            "settWant": want.balanceOf(sett),
            "stratWant": strategy.balanceOf(),
            "rewardsWant": want.balanceOf(controller.rewards()),
        }

        with brownie.reverts():
            controller.withdrawAll(strategy.want(), {"from": randomUser})

        controller.withdrawAll(strategy.want(), {"from": deployer})

        after = {"settWant": want.balanceOf(sett), "stratWant": strategy.balanceOf()}

        assert after["settWant"] > before["settWant"]
        assert after["stratWant"] < before["stratWant"]
        assert after["stratWant"] == 0
    }


    function testWithdrawOther() public {
        """
        - Controller should be able to withdraw other tokens
        - Controller should not be able to withdraw core tokens
        - Non-controller shouldn't be able to do either
        """
        # Setup
        randomUser = accounts[6]
        startingBalance = want.balanceOf(deployer)
        depositAmount = startingBalance // 2
        assert startingBalance >= depositAmount
        # End Setup

        # Deposit
        want.approve(sett, MaxUint256, {"from": deployer})
        sett.deposit(depositAmount, {"from": deployer})

        chain.sleep(15)
        chain.mine()

        sett.earn({"from": deployer})

        chain.sleep(days(0.5))
        chain.mine()

        if strategy.isTendable():
            strategy.tend({"from": deployer})

        strategy.harvest({"from": deployer})

        chain.sleep(days(0.5))
        chain.mine()

        mockAmount = Wei("1000 ether")
        mockToken = MockToken.deploy({"from": deployer})
        mockToken.initialize([strategy], [mockAmount], {"from": deployer})

        assert mockToken.balanceOf(strategy) == mockAmount

        # Should not be able to withdraw protected tokens
        protectedTokens = strategy.getProtectedTokens()
        for token in protectedTokens:
            with brownie.reverts():
                controller.inCaseStrategyTokenGetStuck(strategy, token, {"from": deployer})

        # Should send balance of non-protected token to sender
        controller.inCaseStrategyTokenGetStuck(strategy, mockToken, {"from": deployer})

        with brownie.reverts():
            controller.inCaseStrategyTokenGetStuck(
                strategy, mockToken, {"from": randomUser}
            )

        assert mockToken.balanceOf(controller) == mockAmount
    }


    function testSingleUserHarvestFlowRemoveFees() public {
        # Setup
        randomUser = accounts[6]
        snap = SnapshotManager(vault, strategy, controller, "StrategySnapshot")
        startingBalance = want.balanceOf(deployer)
        tendable = strategy.isTendable()
        startingBalance = want.balanceOf(deployer)
        depositAmount = startingBalance // 2
        assert startingBalance >= depositAmount
        # End Setup

        # Deposit
        want.approve(sett, MaxUint256, {"from": deployer})
        snap.settDeposit(depositAmount, {"from": deployer})

        # Earn
        snap.settEarn({"from": deployer})

        chain.sleep(days(0.5))
        chain.mine()

        if tendable:
            snap.settTend({"from": deployer})

        chain.sleep(days(14))
        voter.distribute({'from': deployer})

        with brownie.reverts("onlyAuthorizedActors"):
            strategy.harvest({"from": randomUser})

        snap.settHarvest({"from": deployer})

        ## NOTE: Some strats do not do this, change accordingly
        # assert want.balanceOf(controller.rewards()) > 0

        chain.sleep(days(1))
        chain.mine()

        if tendable:
            snap.settTend({"from": deployer})

        chain.sleep(days(3))
        chain.mine()

        snap.settHarvest({"from": deployer})

        snap.settWithdrawAll({"from": deployer})

        endingBalance = want.balanceOf(deployer)

        print("Report after 4 days")
        print("Gains")
        print(endingBalance - startingBalance)
        print("gainsPercentage")
        print((endingBalance - startingBalance) / startingBalance)
    }
  */

    /// ============================
    /// ===== Internal helpers =====
    /// ============================

    function depositCheckedFrom(address _from, uint256 _amount) internal {
        uint256 beforeWantBalanceOfFrom = WANT.balanceOf(_from);
        uint256 beforeSettBalanceOfFrom = sett.balanceOf(_from);
        uint256 beforeWantBalanceOfSett = WANT.balanceOf(address(sett));

        uint256 expectedShares = (_amount * 1e18) / sett.getPricePerFullShare();

        vm.startPrank(_from);

        WANT.approve(address(sett), _amount);
        sett.deposit(_amount);

        vm.stopPrank();

        assertEq(WANT.balanceOf(_from), beforeWantBalanceOfFrom.sub(_amount));
        assertEq(
            sett.balanceOf(_from),
            beforeSettBalanceOfFrom.add(expectedShares)
        );
        assertEq(
            WANT.balanceOf(address(sett)),
            beforeWantBalanceOfSett.add(_amount)
        );
    }

    function depositChecked(uint256 _amount) internal {
        depositCheckedFrom(address(this), _amount);
    }

    function earnChecked() internal {
        // TODO: Make calcs exact based on available()
        uint256 beforeWantBalanceOfSett = WANT.balanceOf(address(sett));
        uint256 beforeStrategyBalanceOfPool = strategy.balanceOfPool();

        vm.prank(keeper);
        sett.earn();

        assertLt(WANT.balanceOf(address(sett)), beforeWantBalanceOfSett);
        assertGt(strategy.balanceOfPool(), beforeStrategyBalanceOfPool);
    }

    function withdrawCheckedFrom(address _from, uint256 _shares) internal {
        uint256 beforeSettBalanceOfFrom = sett.balanceOf(_from);
        uint256 beforeWantBalanceOfFrom = WANT.balanceOf(_from);
        uint256 beforeWantBalanceOfSett = WANT.balanceOf(address(sett));
        uint256 beforeWantBalanceOfStrategy = WANT.balanceOf(address(strategy));
        uint256 beforeWantBalanceOfTreasury = WANT.balanceOf(treasury);
        uint256 beforeStrategyBalanceOfPool = strategy.balanceOfPool();

        uint256 expectedAmount = (_shares * sett.getPricePerFullShare()) / 1e18;

        vm.startPrank(_from);

        sett.withdraw(_shares);

        vm.stopPrank();

        assertEq(sett.balanceOf(_from), beforeSettBalanceOfFrom.sub(_shares));

        if (expectedAmount <= beforeWantBalanceOfSett) {
            assertEq(
                WANT.balanceOf(address(sett)),
                beforeWantBalanceOfSett.sub(expectedAmount)
            );
            assertEq(
                WANT.balanceOf(_from),
                beforeWantBalanceOfFrom.add(expectedAmount)
            );
        } else {
            uint256 required = expectedAmount.sub(beforeWantBalanceOfSett);
            uint256 fee = required.mul(strategy.withdrawalFee()).div(MAX_BPS);

            if (required <= beforeWantBalanceOfStrategy) {
                assertEq(WANT.balanceOf(address(sett)), 0);
                assertEq(
                    WANT.balanceOf(address(strategy)),
                    beforeWantBalanceOfStrategy.sub(required)
                );
            } else {
                required = required.sub(beforeWantBalanceOfStrategy);

                assertEq(WANT.balanceOf(address(sett)), 0);
                assertEq(WANT.balanceOf(address(strategy)), 0);
                assertEq(
                    strategy.balanceOfPool(),
                    beforeStrategyBalanceOfPool.sub(required)
                );
            }

            assertEq(
                WANT.balanceOf(_from),
                beforeWantBalanceOfFrom.add(expectedAmount).sub(fee)
            );
            assertEq(
                WANT.balanceOf(treasury),
                beforeWantBalanceOfTreasury.add(fee)
            );
        }
    }

    function withdrawChecked(uint256 _shares) internal {
        withdrawCheckedFrom(address(this), _shares);
    }

    function harvestChecked() internal {
        uint256 performanceFeeGovernance = strategy.performanceFeeGovernance();
        uint256 performanceFeeStrategist = strategy.performanceFeeStrategist();

        // TODO: There has to be a better way to do this
        uint256 beforeSettPricePerFullShare = sett.getPricePerFullShare();
        uint256 beforeStrategyBalanceOf = strategy.balanceOf();

        uint256 beforeBSolidSolidSexBalanceOfGovernance = BSOLID_SOLIDSEX
            .balanceOf(governance);
        uint256 beforeBSolidSolidSexBalanceOfStrategist = BSOLID_SOLIDSEX
            .balanceOf(strategist);
        uint256 beforeBSolidSolidSexBalanceOfBadgerTree = BSOLID_SOLIDSEX
            .balanceOf(BADGER_TREE);

        uint256 beforeBSexWftmBalanceOfGovernance = BSEX_WFTM.balanceOf(
            governance
        );
        uint256 beforeBSexWftmBalanceOfStrategist = BSEX_WFTM.balanceOf(
            strategist
        );
        uint256 beforeBSexWftmBalanceOfBadgerTree = BSEX_WFTM.balanceOf(
            BADGER_TREE
        );

        if (performanceFeeGovernance > 0) {
            vm.expectEmit(true, true, true, false); // Not checking amount
            emit PerformanceFeeGovernance(
                governance,
                address(BSOLID_SOLIDSEX),
                0, // dummy
                block.number,
                block.timestamp
            );

            vm.expectEmit(true, true, true, false); // Not checking amount
            emit PerformanceFeeGovernance(
                governance,
                address(BSEX_WFTM),
                0, // dummy
                block.number,
                block.timestamp
            );
        }

        if (performanceFeeStrategist > 0) {
            vm.expectEmit(true, true, true, false); // Not checking amount
            emit PerformanceFeeStrategist(
                strategist,
                address(BSOLID_SOLIDSEX),
                0, // dummy
                block.number,
                block.timestamp
            );

            vm.expectEmit(true, true, true, false); // Not checking amount
            emit PerformanceFeeStrategist(
                strategist,
                address(BSEX_WFTM),
                0, // dummy
                block.number,
                block.timestamp
            );
        }

        vm.expectEmit(true, false, false, true);
        emit Harvest(0, block.number);

        uint256 harvested = strategy.harvest();

        assertEq(harvested, 0);
        assertEq(sett.getPricePerFullShare(), beforeSettPricePerFullShare);
        assertEq(strategy.balanceOf(), beforeStrategyBalanceOf);

        uint256 deltaBSolidSolidSexBalanceOfGovernance = BSOLID_SOLIDSEX
            .balanceOf(governance)
            .sub(beforeBSolidSolidSexBalanceOfGovernance);
        uint256 deltaBSolidSolidSexBalanceOfStrategist = BSOLID_SOLIDSEX
            .balanceOf(strategist)
            .sub(beforeBSolidSolidSexBalanceOfStrategist);
        uint256 deltaBSolidSolidSexBalanceOfBadgerTree = BSOLID_SOLIDSEX
            .balanceOf(BADGER_TREE)
            .sub(beforeBSolidSolidSexBalanceOfBadgerTree);

        uint256 bSolidSolidSexEmitted = deltaBSolidSolidSexBalanceOfGovernance
            .add(deltaBSolidSolidSexBalanceOfStrategist)
            .add(deltaBSolidSolidSexBalanceOfBadgerTree);

        uint256 deltaBSexWftmBalanceOfGovernance = BSEX_WFTM
            .balanceOf(governance)
            .sub(beforeBSexWftmBalanceOfGovernance);
        uint256 deltaBSexWftmBalanceOfStrategist = BSEX_WFTM
            .balanceOf(strategist)
            .sub(beforeBSexWftmBalanceOfStrategist);
        uint256 deltaBSexWftmBalanceOfBadgerTree = BSEX_WFTM
            .balanceOf(BADGER_TREE)
            .sub(beforeBSexWftmBalanceOfBadgerTree);

        uint256 bSexWftmEmitted = deltaBSexWftmBalanceOfGovernance
            .add(deltaBSexWftmBalanceOfStrategist)
            .add(deltaBSexWftmBalanceOfBadgerTree);

        assertEq(
            deltaBSolidSolidSexBalanceOfGovernance,
            bSolidSolidSexEmitted.mul(performanceFeeGovernance).div(MAX_BPS)
        );
        assertEq(
            deltaBSolidSolidSexBalanceOfStrategist,
            bSolidSolidSexEmitted.mul(performanceFeeStrategist).div(MAX_BPS)
        );
        assertEq(
            deltaBSolidSolidSexBalanceOfBadgerTree,
            bSolidSolidSexEmitted.mul(
                MAX_BPS
                    .sub(performanceFeeGovernance)
                    .sub(performanceFeeStrategist)
                    .div(MAX_BPS)
            )
        );

        assertEq(
            deltaBSexWftmBalanceOfGovernance,
            bSexWftmEmitted.mul(performanceFeeGovernance).div(MAX_BPS)
        );
        assertEq(
            deltaBSexWftmBalanceOfStrategist,
            bSexWftmEmitted.mul(performanceFeeStrategist).div(MAX_BPS)
        );
        assertEq(
            deltaBSexWftmBalanceOfBadgerTree,
            bSexWftmEmitted.mul(
                MAX_BPS
                    .sub(performanceFeeGovernance)
                    .sub(performanceFeeStrategist)
                    .div(MAX_BPS)
            )
        );
    }
}

contract SnapshotManager {
    struct SnapshotTarget {
      address who;
      bytes data;
    }

    struct SnapshotValue {
      uint256 beforeVal;
      uint256 afterVal;
    }

    string[] private snapshotKeys;

    mapping(string => SnapshotKey) private snapshotTargets;
    mapping(string => SnapshotValue) private snapshotValues;

    function snapAdd(string calldata _key, address _who, bytes _data) public {
        snapshotKeys.append(_key);
        snapshotTargets[_key] = SnapshotTarget(_who, _data);
        snapshotValues[_key].afterVal = _who.staticcall(_data);
    }

    function snapTake() public {
        uint256 length = snapshotKeys.length;

        for (uint256 i; i < length; ++i) {
            string memory key = snapshotKeys[i];
            SnapshotTarget target = snapshotTargets[key];
            snapshotValues[key].beforeVal = snapshotValues[key].afterVal;
            snapshotValues[key].afterVal = target.who.staticcall(target.sig, target.data);
        }
    }
}

/*
TODO:
- No upgradeable in test contract
- Refactor everything
- Add guestlist
- Add proxy
*/
