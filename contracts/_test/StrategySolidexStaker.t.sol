// SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import {DSTest} from "ds-test/test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdCheats} from "forge-std/stdlib.sol";
import {ERC20Utils} from "./utils/ERC20Utils.sol";
import {MulticallUtils} from "./utils/MulticallUtils.sol";
import {SnapshotComparator} from "./utils/Snapshot.sol";

import {IERC20Upgradeable} from "../../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeMathUpgradeable} from "../../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {ISettV4h} from "../../interfaces/badger/ISettV4h.sol";

import {StrategySolidexStaker} from "../StrategySolidexStaker.sol";
import {Controller} from "../deps/Controller.sol";
import {SettV4} from "../deps/SettV4.sol";

contract Config is MulticallUtils {
    IERC20Upgradeable public constant WANT =
        IERC20Upgradeable(0xC0240Ee4405f11EFb87A00B432A8be7b7Afc97CC);

    ISettV4h public constant BSOLID_SOLIDSEX =
        ISettV4h(0xC7cBF5a24caBA375C09cc824481F5508c644dF28);
    ISettV4h public constant BSEX_WFTM =
        ISettV4h(0x7cc6049a125388B51c530e51727A87aE101f6417);

    uint256 public constant PERFORMANCE_FEE_GOVERNANCE = 1_500;
    uint256 public constant PERFORMANCE_FEE_STRATEGIST = 0;
    uint256 public constant WITHDRAWAL_FEE = 10;

    address public constant BADGER_REGISTRY =
        0xFda7eB6f8b7a9e9fCFd348042ae675d1d652454f;

    address public constant BADGER_DEV_MULTISIG =
        0x4c56ee3295042f8A5dfC83e770a21c707CB46f5b;
    address public constant BADGER_TREE =
        0x89122c767A5F543e663DB536b603123225bc3823;

    address public immutable MULTICALL = getMulticall();
}

contract StrategySolidexStakerTest is DSTest, stdCheats, Config {
    using SafeMathUpgradeable for uint256;

    // ==============
    // ===== Vm =====
    // ==============

    Vm constant vm = Vm(HEVM_ADDRESS);

    ERC20Utils immutable erc20utils = new ERC20Utils();
    SnapshotComparator comparator;

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

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant AMOUNT_TO_MINT = 10e18;

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

        vm.prank(BSOLID_SOLIDSEX.governance());
        BSOLID_SOLIDSEX.approveContractAccess(address(strategy));

        vm.prank(BSEX_WFTM.governance());
        BSEX_WFTM.approveContractAccess(address(strategy));

        erc20utils.forceMint(address(WANT), AMOUNT_TO_MINT);

        comparator = new SnapshotComparator(MULTICALL);
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
        uint256 amount = WANT.balanceOf(address(this));

        depositChecked(amount);
        earnChecked();

        skip(1 days);
        harvestChecked();
    }

    function testPerformanceFees(
        uint16 _performanceFeeGovernance,
        uint16 _performanceFeeStrategist
    ) public {
        vm.assume(
            _performanceFeeGovernance + _performanceFeeStrategist <= MAX_BPS
        );

        uint256 amount = WANT.balanceOf(address(this));

        depositChecked(amount);
        earnChecked();

        strategy.setPerformanceFeeGovernance(_performanceFeeGovernance);
        strategy.setPerformanceFeeStrategist(_performanceFeeStrategist);

        skip(1 days);
        harvestChecked();
    }

    function testDepositIsProtected() public {
        vm.expectRevert("onlyAuthorizedActorsOrController");
        strategy.deposit();
    }

    function testGovernanceCanDeposit() public {
        vm.prank(governance);
        strategy.deposit();
    }

    function testKeeperCanDeposit() public {
        vm.prank(keeper);
        strategy.deposit();
    }

    function testHarvestIsProtected() public {
        vm.expectRevert("onlyAuthorizedActors");
        strategy.harvest();
    }

    function testGovernanceCanHarvest() public {
        vm.prank(governance);
        strategy.deposit();
    }

    function testKeeperCanHarvest() public {
        vm.prank(keeper);
        strategy.deposit();
    }

    function testWithdrawIsProtected() public {
        address[4] memory actors = [
            address(this),
            governance,
            strategist,
            keeper
        ];
        uint256 length = actors.length;

        for (uint256 i; i < length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert("onlyController");
            strategy.withdraw(1);
        }
    }

    function testWithdrawAllIsProtected() public {
        address[4] memory actors = [
            address(this),
            governance,
            strategist,
            keeper
        ];
        uint256 length = actors.length;

        for (uint256 i; i < length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert("onlyController");
            strategy.withdrawAll();
        }
    }

    function testWithdrawOtherIsProtected() public {
        address[4] memory actors = [
            address(this),
            governance,
            strategist,
            keeper
        ];
        uint256 length = actors.length;

        for (uint256 i; i < length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert("onlyController");
            strategy.withdrawOther(address(controller));
        }
    }

    function testSetGuardian() public {
        vm.prank(governance);
        strategy.setGuardian(address(0));

        assertEq(strategy.guardian(), address(0));
    }

    function testSetGuardianIsProtected() public {
        vm.expectRevert("onlyGovernance");
        strategy.setGuardian(address(0));
    }

    function testSetController() public {
        vm.prank(governance);
        strategy.setController(address(0));

        assertEq(strategy.controller(), address(0));
    }

    function testSetControllerIsProtected() public {
        vm.expectRevert("onlyGovernance");
        strategy.setController(address(0));
    }

    function testSetPerformanceFeeGovernance() public {
        vm.prank(governance);
        strategy.setPerformanceFeeGovernance(0);

        assertEq(strategy.performanceFeeGovernance(), 0);
    }

    function testSetPerformanceFeeGovernanceIsProtected() public {
        vm.expectRevert("onlyGovernance");
        strategy.setPerformanceFeeGovernance(0);
    }

    function testSetPerformanceFeeStrategist() public {
        vm.prank(governance);
        strategy.setPerformanceFeeStrategist(0);

        assertEq(strategy.performanceFeeStrategist(), 0);
    }

    function testSetPerformanceFeeStrategistIsProtected() public {
        vm.expectRevert("onlyGovernance");
        strategy.setPerformanceFeeStrategist(0);
    }

    function testSetWithdrawalFee() public {
        vm.prank(governance);
        strategy.setWithdrawalFee(0);

        assertEq(strategy.withdrawalFee(), 0);
    }

    function testSetWithdrawalFeeIsProtected() public {
        vm.expectRevert("onlyGovernance");
        strategy.setWithdrawalFee(0);
    }

    function testGovernanceCanPause() public {
        vm.prank(governance);
        strategy.pause();

        assertTrue(strategy.paused());
    }

    function testGuardianCanPause() public {
        vm.prank(guardian);
        strategy.pause();

        assertTrue(strategy.paused());
    }

    function testPauseIsProtected() public {
        vm.expectRevert("onlyPausers");
        strategy.pause();
    }

    function testGovernanceCanUnpause() public {
        vm.prank(guardian);
        strategy.pause();

        vm.prank(governance);
        strategy.unpause();

        assertTrue(!strategy.paused());
    }

    function testUnpauseIsProtected() public {
        address[2] memory actors = [address(this), guardian];
        uint256 length = actors.length;

        for (uint256 i; i < length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert("onlyGovernance");
            strategy.unpause();
        }
    }

    function testWithdrawAllFailsWhenPaused() public {
        vm.prank(address(controller));
        vm.expectRevert("Pausable: paused");
        sett.withdrawAll();
    }

    function testGovernanceCanEarn() public {
        vm.prank(governance);
        sett.earn();
    }

    function testKeeperCanEarn() public {
        vm.prank(keeper);
        sett.earn();
    }

    function testEarnIsProtected() public {
        vm.expectRevert("onlyAuthorizedActors");
        sett.earn();
    }

    function testSetMin() public {
        vm.prank(governance);
        sett.setMin(0);

        assertEq(sett.min(), 0);
    }

    function testSetMinIsProtected() public {
        vm.expectRevert("onlyGovernance");
        sett.setMin(0);
    }

    function testSettSetController() public {
        vm.prank(governance);
        sett.setController(address(0));

        assertEq(sett.controller(), address(0));
    }

    function testSettSetControllerIsProtected() public {
        vm.expectRevert("onlyGovernance");
        sett.setController(address(0));
    }

    function testSetStrategist() public {
        vm.prank(governance);
        sett.setStrategist(address(0));

        assertEq(sett.strategist(), address(0));
    }

    function testSetStrategistIsProtected() public {
        vm.expectRevert("onlyGovernance");
        sett.setStrategist(address(0));
    }

    function testSetKeeper() public {
        vm.prank(governance);
        sett.setKeeper(address(0));

        assertEq(sett.keeper(), address(0));
    }

    function testSetKeeperIsProtected() public {
        vm.expectRevert("onlyGovernance");
        sett.setKeeper(address(0));
    }

    function testSettGovernanceCanPause() public {
        vm.prank(governance);
        sett.pause();

        assertTrue(sett.paused());
    }

    function testSettGuardianCanPause() public {
        vm.prank(guardian);
        sett.pause();

        assertTrue(sett.paused());
    }

    function testSettPauseIsProtected() public {
        vm.expectRevert("onlyPausers");
        sett.pause();
    }

    /// ===========================
    /// ===== Lifecycle Tests =====
    /// ===========================

    // TODO: Maybe remove withdrawal fees here?
    function testHarvestFlow() public {
        uint256 amount = WANT.balanceOf(address(this));

        uint256 shares = depositChecked(amount);
        earnChecked();

        skip(1 days);
        harvestChecked();

        uint256 amountAfter = withdrawChecked(shares);

        assertGt(amountAfter, amount);
    }

    function testDepositOnce() public {
        uint256 amount = WANT.balanceOf(address(this));
        depositChecked(amount);
    }

    function testEarn() public {
        uint256 amount = WANT.balanceOf(address(this));

        depositChecked(amount);
        earnChecked();
    }

    function testWithdrawOnce() public {
        uint256 amount = WANT.balanceOf(address(this));

        uint256 shares = depositChecked(amount);
        earnChecked();

        // vm.roll(block.number + 1);
        withdrawChecked(shares);
    }

    function testWithdrawTwice() public {
        uint256 amount = WANT.balanceOf(address(this));

        uint256 shares = depositChecked(amount);
        earnChecked();

        withdrawChecked(shares.div(2));
        withdrawChecked(shares.sub(shares.div(2)));
    }

    function testWithdrawAll() public {
        uint256 amount = WANT.balanceOf(address(this));

        depositChecked(amount);
        earnChecked();

        controllerWithrawAllChecked();
    }

    /// ============================
    /// ===== Internal helpers =====
    /// ============================

    function depositCheckedFrom(address _from, uint256 _amount)
        internal
        returns (uint256 shares_)
    {
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
        vm.startPrank(_from, _from);

        WANT.approve(address(sett), _amount);
        sett.deposit(_amount);

        vm.stopPrank();
        comparator.snapCurr();

        comparator.assertNegDiff("want.balanceOf(from)", _amount);
        comparator.assertDiff("want.balanceOf(sett)", _amount);
        comparator.assertDiff("sett.balanceOf(from)", expectedShares);

        shares_ = comparator.diff("sett.balanceOf(from)");
    }

    function depositChecked(uint256 _amount)
        internal
        returns (uint256 shares_)
    {
        shares_ = depositCheckedFrom(address(this), _amount);
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

        uint256 expectedEarn = WANT
            .balanceOf(address(sett))
            .mul(sett.min())
            .div(MAX_BPS);

        comparator.snapPrev();
        vm.prank(keeper);

        sett.earn();

        comparator.snapCurr();

        comparator.assertNegDiff("want.balanceOf(sett)", expectedEarn);
        comparator.assertDiff("strategy.balanceOfPool()", expectedEarn);
    }

    function withdrawCheckedFrom(address _from, uint256 _shares)
        internal
        returns (uint256 amount_)
    {
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
        vm.prank(_from, _from);

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

        amount_ = comparator.diff("want.balanceOf(from)");
    }

    function withdrawChecked(uint256 _shares)
        internal
        returns (uint256 amount_)
    {
        amount_ = withdrawCheckedFrom(address(this), _shares);
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
            "bSolidSolidSex.balanceOf(treasury)",
            address(BSOLID_SOLIDSEX),
            abi.encodeWithSignature("balanceOf(address)", treasury)
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
            "bSexWftm.balanceOf(treasury)",
            address(BSEX_WFTM),
            abi.encodeWithSignature("balanceOf(address)", treasury)
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

        comparator.snapPrev();
        vm.prank(keeper);

        if (performanceFeeGovernance > 0) {
            vm.expectEmit(true, true, true, false); // Not checking amount
            emit PerformanceFeeGovernance(
                treasury,
                address(BSOLID_SOLIDSEX),
                0, // dummy
                block.number,
                block.timestamp
            );

            vm.expectEmit(true, true, true, false); // Not checking amount
            emit PerformanceFeeGovernance(
                treasury,
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

        comparator.snapCurr();

        assertEq(harvested, 0);

        comparator.assertEq("sett.getPricePerFullShare()");
        comparator.assertEq("strategy.balanceOf()");

        {
            uint256 deltaBSolidSolidSexBalanceOfTreasury = comparator.diff(
                "bSolidSolidSex.balanceOf(treasury)"
            );
            uint256 deltaBSolidSolidSexBalanceOfStrategist = comparator.diff(
                "bSolidSolidSex.balanceOf(strategist)"
            );
            uint256 deltaBSolidSolidSexBalanceOfBadgerTree = comparator.diff(
                "bSolidSolidSex.balanceOf(badgerTree)"
            );

            uint256 bSolidSolidSexEmitted = deltaBSolidSolidSexBalanceOfTreasury
                .add(deltaBSolidSolidSexBalanceOfStrategist)
                .add(deltaBSolidSolidSexBalanceOfBadgerTree);

            uint256 bSolidSolidSexGovernanceFee = bSolidSolidSexEmitted
                .mul(performanceFeeGovernance)
                .div(MAX_BPS);
            uint256 bSolidSolidSexStrategistFee = bSolidSolidSexEmitted
                .mul(performanceFeeStrategist)
                .div(MAX_BPS);

            assertEq(
                deltaBSolidSolidSexBalanceOfTreasury,
                bSolidSolidSexGovernanceFee
            );
            assertEq(
                deltaBSolidSolidSexBalanceOfStrategist,
                bSolidSolidSexStrategistFee
            );
            assertEq(
                deltaBSolidSolidSexBalanceOfBadgerTree,
                bSolidSolidSexEmitted.sub(bSolidSolidSexGovernanceFee).sub(
                    bSolidSolidSexStrategistFee
                )
            );
        }

        {
            uint256 deltaBSexWftmBalanceOfTreasury = comparator.diff(
                "bSexWftm.balanceOf(treasury)"
            );
            uint256 deltaBSexWftmBalanceOfStrategist = comparator.diff(
                "bSexWftm.balanceOf(strategist)"
            );
            uint256 deltaBSexWftmBalanceOfBadgerTree = comparator.diff(
                "bSexWftm.balanceOf(badgerTree)"
            );

            uint256 bSexWftmEmitted = deltaBSexWftmBalanceOfTreasury
                .add(deltaBSexWftmBalanceOfStrategist)
                .add(deltaBSexWftmBalanceOfBadgerTree);

            uint256 bSexWftmGovernanceFee = bSexWftmEmitted
                .mul(performanceFeeGovernance)
                .div(MAX_BPS);
            uint256 bSexWftmStrategistFee = bSexWftmEmitted
                .mul(performanceFeeStrategist)
                .div(MAX_BPS);

            assertEq(deltaBSexWftmBalanceOfTreasury, bSexWftmGovernanceFee);
            assertEq(deltaBSexWftmBalanceOfStrategist, bSexWftmStrategistFee);
            assertEq(
                deltaBSexWftmBalanceOfBadgerTree,
                bSexWftmEmitted.sub(bSexWftmGovernanceFee).sub(
                    bSexWftmStrategistFee
                )
            );
        }
    }

    function controllerWithrawAllChecked() internal {
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

        comparator.snapPrev();
        vm.prank(governance);

        controller.withdrawAll(strategy.want());

        comparator.snapCurr();

        assertEq(comparator.curr("want.balanceOf(strategy)"), 0);
        comparator.assertDiff(
            "want.balanceOf(sett)",
            comparator.prev("want.balanceOf(strategy)")
        );
    }
}

/*
TODO:
- No upgradeable in test contract
- Refactor everything
- Generalize
- Add guestlist
- Add proxy
- EOA lock
*/
