// SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

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

    uint256 public constant PERFORMANCE_FEE_GOVERNANCE = 1_500;
    uint256 public constant PERFORMANCE_FEE_STRATEGIST = 0;
    uint256 public constant WITHDRAWAL_FEE = 10;

    address public constant BADGER_REGISTRY =
        0xFda7eB6f8b7a9e9fCFd348042ae675d1d652454f;

    address public constant BADGER_DEV_MULTISIG =
        0x4c56ee3295042f8A5dfC83e770a21c707CB46f5b;
    address public constant BADGER_TREE =
        0x89122c767A5F543e663DB536b603123225bc3823;
}

contract MulticallRegistry {
    mapping(uint256 => address) private addresses;

    constructor() public {
        addresses[1] = 0xeefBa1e63905eF1D7ACbA5a8513c70307C1cE441;
        addresses[4] = 0x42Ad527de7d4e9d9d011aC45B31D8551f8Fe9821;
        addresses[5] = 0x77dCa2C955b15e9dE4dbBCf1246B4B85b651e50e;
        addresses[42] = 0x2cc8688C5f75E365aaEEb4ea8D6a480405A48D2A;
        addresses[56] = 0xeC8c00dA6ce45341FB8c31653B598Ca0d8251804;
        addresses[100] = 0xb5b692a88BDFc81ca69dcB1d924f59f0413A602a;
        addresses[250] = 0xb828C456600857abd4ed6C32FAcc607bD0464F4F;
        addresses[42161] = 0x7A7443F8c577d537f1d8cD4a629d40a3148Dd7ee;
    }

    function get(uint256 _chainId) public view returns (address multicall_) {
        multicall_ = addresses[_chainId];
        require(multicall_ != address(0), "Not in registry");
    }
}

abstract contract Utils {
    Vm constant vmUtils =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // TODO: Default to 99?
    function getChainIdOfHead() public returns (uint256 chainId_) {
        string[] memory inputs = new string[](2);
        inputs[0] = "bash";
        inputs[1] = "scripts/chain-id.sh";
        chainId_ = abi.decode(vmUtils.ffi(inputs), (uint256));
    }

    // TODO: Deploy if not there?
    function getMulticall() public returns (address multicall_) {
        MulticallRegistry multicallRegistry = new MulticallRegistry();
        multicall_ = multicallRegistry.get(getChainIdOfHead());
    }
}

contract StrategySolidexStakerTest is DSTest, stdCheats, Utils, Config {
    using SafeMathUpgradeable for uint256;

    // ==============
    // ===== Vm =====
    // ==============

    Vm constant vm = Vm(HEVM_ADDRESS);

    ERC20Utils immutable erc20utils = new ERC20Utils();
    SnapshotComparator immutable comparator =
        new SnapshotComparator(getMulticall());

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

    /*
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
        comparator.addCall(
            "want.balanceOf(from)",
            address(WANT),
            abi.encodeWithSignature("balanceOf(address)", _from)
        );
        comparator.addCall(
            "want.balanceOf(sett)",
            address(WANT),
            abi.encodeWithSignature("balanceOf(address)", address(sett))
        );
        comparator.addCall(
            "sett.balanceOf(from)",
            address(sett),
            abi.encodeWithSignature("balanceOf(address)", _from)
        );

        uint256 expectedShares = _amount.mul(1e18).div(
            sett.getPricePerFullShare()
        );

        comparator.snapPrev();
        vm.startPrank(_from);

        WANT.approve(address(sett), _amount);
        sett.deposit(_amount);

        vm.stopPrank();
        comparator.snapCurr();

        comparator.assertNegDiff("want.balanceOf(from)", _amount);
        comparator.assertDiff("want.balanceOf(sett)", _amount);
        comparator.assertDiff("sett.balanceOf(from)", expectedShares);
    }

    function depositChecked(uint256 _amount) internal {
        depositCheckedFrom(address(this), _amount);
    }

    function earnChecked() internal {
        comparator.addCall(
            "want.balanceOf(sett)",
            address(WANT),
            abi.encodeWithSignature("balanceOf(address)", address(sett))
        );
        comparator.addCall(
            "strategy.balanceOfPool()",
            address(strategy),
            abi.encodeWithSignature("balanceOfPool()")
        );

        uint256 expectedEarn = WANT.balanceOf(address(sett)).mul(
            MAX_BPS.sub(sett.min()).div(MAX_BPS)
        );

        comparator.snapPrev();
        vm.prank(keeper);

        sett.earn();

        comparator.snapCurr();

        comparator.assertNegDiff("want.balanceOf(sett)", expectedEarn);
        comparator.assertDiff("strategy.balanceOfPool()", expectedEarn);
    }

    function withdrawCheckedFrom(address _from, uint256 _shares) internal {
        comparator.addCall(
            "sett.balanceOf(from)",
            address(sett),
            abi.encodeWithSignature("balanceOf(address)", _from)
        );
        comparator.addCall(
            "want.balanceOf(from)",
            address(WANT),
            abi.encodeWithSignature("balanceOf(address)", _from)
        );
        comparator.addCall(
            "want.balanceOf(sett)",
            address(WANT),
            abi.encodeWithSignature("balanceOf(address)", address(sett))
        );
        comparator.addCall(
            "want.balanceOf(strategy)",
            address(WANT),
            abi.encodeWithSignature("balanceOf(address)", address(strategy))
        );
        comparator.addCall(
            "want.balanceOf(treasury)",
            address(WANT),
            abi.encodeWithSignature("balanceOf(address)", treasury)
        );
        comparator.addCall(
            "strategy.balanceOfPool()",
            address(strategy),
            abi.encodeWithSignature("balanceOfPool()")
        );

        uint256 expectedAmount = _shares.mul(sett.getPricePerFullShare()).div(
            1e18
        );

        comparator.snapPrev();
        vm.prank(_from);

        sett.withdraw(_shares);

        comparator.snapCurr();

        comparator.assertNegDiff("sett.balanceOf(from)", _shares);

        if (expectedAmount <= comparator.prev("want.balanceOf(sett)")) {
            comparator.assertNegDiff("want.balanceOf(sett)", expectedAmount);
            comparator.assertDiff("want.balanceOf(from)", expectedAmount);
        } else {
            uint256 required = expectedAmount.sub(
                comparator.prev("want.balanceOf(sett)")
            );
            uint256 fee = required.mul(strategy.withdrawalFee()).div(MAX_BPS);

            if (required <= comparator.prev("want.balanceOf(strategy)")) {
                assertEq(comparator.curr("want.balanceOf(sett)"), 0);
                comparator.assertNegDiff("want.balanceOf(strategy)", required);
            } else {
                required = required.sub(
                    comparator.prev("want.balanceOf(strategy)")
                );

                assertEq(comparator.curr("want.balanceOf(sett)"), 0);
                assertEq(comparator.curr("want.balanceOf(strategy)"), 0);
                comparator.assertNegDiff("strategy.balanceOfPool()", required);
            }

            comparator.assertDiff(
                "want.balanceOf(from)",
                expectedAmount.sub(fee)
            );
            comparator.assertDiff("want.balanceOf(treasury)", fee);
        }
    }

    function withdrawChecked(uint256 _shares) internal {
        withdrawCheckedFrom(address(this), _shares);
    }

    function harvestChecked() internal {
        uint256 performanceFeeGovernance = strategy.performanceFeeGovernance();
        uint256 performanceFeeStrategist = strategy.performanceFeeStrategist();

        // TODO: There has to be a better way to do this
        comparator.addCall(
            "sett.getPricePerFullShare()",
            address(sett),
            abi.encodeWithSignature("getPricePerFullShare()")
        );
        comparator.addCall(
            "strategy.balanceOf()",
            address(strategy),
            abi.encodeWithSignature("balanceOf()")
        );

        comparator.addCall(
            "bSolidSolidSex.balanceOf(governance)",
            address(BSOLID_SOLIDSEX),
            abi.encodeWithSignature("balanceOf(address)", governance)
        );
        comparator.addCall(
            "bSolidSolidSex.balanceOf(strategist)",
            address(BSOLID_SOLIDSEX),
            abi.encodeWithSignature("balanceOf(address)", strategist)
        );
        comparator.addCall(
            "bSolidSolidSex.balanceOf(badgerTree)",
            address(BSOLID_SOLIDSEX),
            abi.encodeWithSignature("balanceOf(address)", BADGER_TREE)
        );

        comparator.addCall(
            "bSexWftm.balanceOf(governance)",
            address(BSEX_WFTM),
            abi.encodeWithSignature("balanceOf(address)", governance)
        );
        comparator.addCall(
            "bSexWftm.balanceOf(strategist)",
            address(BSEX_WFTM),
            abi.encodeWithSignature("balanceOf(address)", strategist)
        );
        comparator.addCall(
            "bSexWftm.balanceOf(badgerTree)",
            address(BSEX_WFTM),
            abi.encodeWithSignature("balanceOf(address)", BADGER_TREE)
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

        comparator.snapPrev();

        vm.expectEmit(true, false, false, true);
        emit Harvest(0, block.number);

        uint256 harvested = strategy.harvest();

        comparator.snapCurr();

        assertEq(harvested, 0);

        comparator.assertEq("sett.getPricePerFullShare()");
        comparator.assertEq("strategy.balanceOf()");

        {
            uint256 deltaBSolidSolidSexBalanceOfGovernance = comparator.diff(
                "bSolidSolidSex.balanceOf(governance)"
            );
            uint256 deltaBSolidSolidSexBalanceOfStrategist = comparator.diff(
                "bSolidSolidSex.balanceOf(strategist)"
            );
            uint256 deltaBSolidSolidSexBalanceOfBadgerTree = comparator.diff(
                "bSolidSolidSex.balanceOf(badgerTree)"
            );

            uint256 bSolidSolidSexEmitted = deltaBSolidSolidSexBalanceOfGovernance
                    .add(deltaBSolidSolidSexBalanceOfStrategist)
                    .add(deltaBSolidSolidSexBalanceOfBadgerTree);

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
        }

        {
            uint256 deltaBSexWftmBalanceOfGovernance = comparator.diff(
                "bSexWftm.balanceOf(governance)"
            );
            uint256 deltaBSexWftmBalanceOfStrategist = comparator.diff(
                "bSexWftm.balanceOf(strategist)"
            );
            uint256 deltaBSexWftmBalanceOfBadgerTree = comparator.diff(
                "bSexWftm.balanceOf(badgerTree)"
            );

            uint256 bSexWftmEmitted = deltaBSexWftmBalanceOfGovernance
                .add(deltaBSexWftmBalanceOfStrategist)
                .add(deltaBSexWftmBalanceOfBadgerTree);

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
}

// TODO: There has to be a better way to do this

contract Snapshot {
    mapping(string => uint256) private values;
    mapping(string => bool) public exists;

    constructor(string[] memory _keys, uint256[] memory _vals) public {
        uint256 length = _keys.length;
        for (uint256 i; i < length; ++i) {
            exists[_keys[i]] = true;
            values[_keys[i]] = _vals[i];
        }
    }

    function valOf(string calldata _key) public view returns (uint256 val_) {
        require(exists[_key], "Invalid key");
        val_ = values[_key];
    }
}

// TODO: Ideally a library
contract SnapshotUtils is DSTest {
    using SafeMathUpgradeable for uint256;

    function diff(
        Snapshot _snap1,
        Snapshot _snap2,
        string calldata _key
    ) public view returns (uint256 val_) {
        val_ = _snap1.valOf(_key).sub(_snap2.valOf(_key));
    }

    function assertEq(
        Snapshot _snap1,
        Snapshot _snap2,
        string calldata _key
    ) public {
        assertEq(_snap1.valOf(_key), _snap2.valOf(_key));
    }

    function assertGt(
        Snapshot _snap1,
        Snapshot _snap2,
        string calldata _key
    ) public {
        assertGt(_snap1.valOf(_key), _snap2.valOf(_key));
    }

    function assertLt(
        Snapshot _snap1,
        Snapshot _snap2,
        string calldata _key
    ) public {
        assertLt(_snap1.valOf(_key), _snap2.valOf(_key));
    }

    function assertGe(
        Snapshot _snap1,
        Snapshot _snap2,
        string calldata _key
    ) public {
        assertGe(_snap1.valOf(_key), _snap2.valOf(_key));
    }

    function assertLe(
        Snapshot _snap1,
        Snapshot _snap2,
        string calldata _key
    ) public {
        assertLe(_snap1.valOf(_key), _snap2.valOf(_key));
    }

    function assertDiff(
        Snapshot _snap1,
        Snapshot _snap2,
        string calldata _key,
        uint256 _diff
    ) public {
        assertEq(_snap1.valOf(_key).sub(_snap2.valOf(_key)), _diff);
    }
}

struct Call {
    address target;
    bytes callData;
}

interface IMulticall {
    function aggregate(Call[] memory calls)
        external
        returns (uint256 blockNumber, bytes[] memory returnData);
}

contract SnapshotManager {
    IMulticall multicall;

    string[] private keys;
    mapping(string => bool) public exists;

    Call[] private calls;

    constructor(address _multicall) public {
        multicall = IMulticall(_multicall);
    }

    function addCall(
        string calldata _key,
        address _target,
        bytes calldata _callData
    ) public {
        if (!exists[_key]) {
            exists[_key] = true;
            keys.push(_key);
            calls.push(Call(_target, _callData));
        }
    }

    function snap() public returns (Snapshot snap_) {
        (, bytes[] memory rdata) = multicall.aggregate(calls);
        uint256 length = rdata.length;

        uint256[] memory vals = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            vals[i] = abi.decode(rdata[i], (uint256));
        }

        snap_ = new Snapshot(keys, vals);
    }
}

contract SnapshotComparator is SnapshotManager, SnapshotUtils {
    Snapshot private sCurr;
    Snapshot private sPrev;

    constructor(address _multicall) public SnapshotManager(_multicall) {}

    function snapPrev() public {
        sPrev = snap();
    }

    function snapCurr() public {
        sCurr = snap();
    }

    function curr(string calldata _key) public view returns (uint256 val_) {
        val_ = sCurr.valOf(_key);
    }

    function prev(string calldata _key) public view returns (uint256 val_) {
        val_ = sPrev.valOf(_key);
    }

    function diff(string calldata _key) public view returns (uint256 val_) {
        val_ = sPrev.valOf(_key);
    }

    function negDiff(string calldata _key) public view returns (uint256 val_) {
        val_ = diff(sPrev, sCurr, _key);
    }

    function assertEq(string calldata _key) public {
        assertEq(sCurr, sPrev, _key);
    }

    function assertGt(string calldata _key) public {
        assertGt(sCurr, sPrev, _key);
    }

    function assertLt(string calldata _key) public {
        assertLt(sCurr, sPrev, _key);
    }

    function assertGe(string calldata _key) public {
        assertGe(sCurr, sPrev, _key);
    }

    function assertLe(string calldata _key) public {
        assertLe(sCurr, sPrev, _key);
    }

    function assertDiff(string calldata _key, uint256 _diff) public {
        assertDiff(sCurr, sPrev, _key, _diff);
    }

    function assertNegDiff(string calldata _key, uint256 _diff) public {
        assertDiff(sPrev, sCurr, _key, _diff);
    }
}

/*
TODO:
- No upgradeable in test contract
- Refactor everything
- Add guestlist
- Add proxy
*/
