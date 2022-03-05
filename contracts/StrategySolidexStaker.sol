// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/uniswap/IUniswapRouterV2.sol";
import "../interfaces/badger/IController.sol";
import "../interfaces/badger/ISettV4h.sol";
import "../interfaces/solidex/ILpDepositor.sol";
import "../interfaces/solidly/IBaseV1Router01.sol";

import {route} from "../interfaces/solidly/IBaseV1Router01.sol";
import {BaseStrategy} from "../deps/BaseStrategy.sol";

contract StrategySolidexStaker is BaseStrategy {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // Solidex
    ILpDepositor public constant lpDepositor =
        ILpDepositor(0x26E1A0d851CF28E697870e1b7F053B605C8b060F);

    // Solidly
    address public constant router = 0xa38cd27185a464914D3046f0AB9d43356B34829D;

    // ===== Token Registry =====

    IERC20Upgradeable public constant solid =
        IERC20Upgradeable(0x888EF71766ca594DED1F0FA3AE64eD2941740A20);
    IERC20Upgradeable public constant solidSex =
        IERC20Upgradeable(0x41adAc6C1Ff52C5e27568f27998d747F7b69795B);

    IERC20Upgradeable public constant sex =
        IERC20Upgradeable(0xD31Fcd1f7Ba190dBc75354046F6024A9b86014d7);
    IERC20Upgradeable public constant wftm =
        IERC20Upgradeable(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

    IERC20Upgradeable public constant solidSolidSexLp =
        IERC20Upgradeable(0x62E2819Dd417F3b430B6fa5Fd34a49A377A02ac8);
    IERC20Upgradeable public constant sexWftmLp =
        IERC20Upgradeable(0xFCEC86aF8774d69e2e4412B8De3f4aBf1f671ecC);

    ISettV4h public constant solidHelperVault =
        ISettV4h(0xC7cBF5a24caBA375C09cc824481F5508c644dF28);
    ISettV4h public constant sexHelperVault =
        ISettV4h(0x7cc6049a125388B51c530e51727A87aE101f6417);

    address public constant badgerTree =
        0x89122c767A5F543e663DB536b603123225bc3823;

    // Constants
    uint256 public constant MAX_BPS = 10000;

    // slippage tolerance 0.5% (divide by MAX_BPS) - Changeable by Governance or Strategist
    uint256 public sl;

    // Used to signal to the Badger Tree that rewards where sent to it
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

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address _want,
        uint256[3] calldata _feeConfig
    ) public initializer {
        __BaseStrategy_init(
            _governance,
            _strategist,
            _controller,
            _keeper,
            _guardian
        );
        /// @dev Add config here
        want = _want;

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        // Set default slippage value
        sl = 50;

        /// @dev do one off approvals here
        IERC20Upgradeable(want).safeApprove(
            address(lpDepositor),
            type(uint256).max
        );

        solid.safeApprove(router, type(uint256).max);
        solidSex.safeApprove(router, type(uint256).max);
        sex.safeApprove(router, type(uint256).max);
        wftm.safeApprove(router, type(uint256).max);

        solidSolidSexLp.safeApprove(
            address(solidHelperVault),
            type(uint256).max
        );
        sexWftmLp.safeApprove(address(sexHelperVault), type(uint256).max);
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external pure override returns (string memory) {
        return "StrategySolidexStaker";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public view override returns (uint256) {
        return lpDepositor.userBalances(address(this), want);
    }

    /// @dev Returns true if this strategy requires tending
    function isTendable() public view override returns (bool) {
        return false;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens()
        public
        view
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](5);
        protectedTokens[0] = want;
        protectedTokens[1] = address(solid);
        protectedTokens[2] = address(solidSex);
        protectedTokens[3] = address(sex);
        protectedTokens[4] = address(wftm);
        return protectedTokens;
    }

    /// @notice sets slippage tolerance for liquidity provision
    function setSlippageTolerance(uint256 _s) external whenNotPaused {
        _onlyGovernanceOrStrategist();
        sl = _s;
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        uint256 numTokens = protectedTokens.length;
        for (uint256 i; i < numTokens; i++) {
            require(
                address(protectedTokens[i]) != _asset,
                "Asset is protected"
            );
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        lpDepositor.deposit(want, _amount);
    }

    /// @dev utility function to withdraw everything for migration
    function _withdrawAll() internal override {
        lpDepositor.withdraw(want, balanceOfPool());
    }

    /// @dev withdraw the specified amount of want, liquidate from lpComponent to want, paying off any necessary debt for the conversion
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        lpDepositor.withdraw(want, _amount);
        return _amount;
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256) {
        _onlyAuthorizedActors();

        // 1. Claim rewards
        address[] memory pools = new address[](1);
        pools[0] = want;
        lpDepositor.getReward(pools);

        // 2. Process SOLID into SOLID/SOLIDsex LP
        uint256 solidBalance = solid.balanceOf(address(this));
        if (solidBalance > 0) {
            // Swap half of SOLID for SOLIDsex
            uint256 _half = solidBalance.mul(5000).div(MAX_BPS);
            _swapExactTokensForTokens(
                router,
                _half,
                route(address(solid), address(solidSex), true) // True to use the stable route
            );

            // Provide liquidity for SOLID/SOLIDsex LP pair
            uint256 _solidIn = solid.balanceOf(address(this));
            uint256 _solidSexIn = solidSex.balanceOf(address(this));
            IBaseV1Router01(router).addLiquidity(
                address(solid),
                address(solidSex),
                true, // Stable
                _solidIn,
                _solidSexIn,
                _solidIn.mul(sl).div(MAX_BPS),
                _solidSexIn.mul(sl).div(MAX_BPS),
                address(this),
                now
            );

            _processRewardLpTokens(solidSolidSexLp, solidHelperVault);
        }

        // 3. Process SEX into SEX/wFTM LP
        uint256 sexBalance = sex.balanceOf(address(this));
        if (sexBalance > 0) {
            // Swap half of SEX for wFTM
            uint256 _half = sexBalance.mul(5000).div(MAX_BPS);
            _swapExactTokensForTokens(
                router,
                _half,
                route(address(sex), address(wftm), false) // False to use the volatile route
            );

            // Provide liquidity for SEX/WFTM LP pair
            uint256 _sexIn = sex.balanceOf(address(this));
            uint256 _wftmIn = wftm.balanceOf(address(this));
            IBaseV1Router01(router).addLiquidity(
                address(sex),
                address(wftm),
                false, // Volatile
                _sexIn,
                _wftmIn,
                _sexIn.mul(sl).div(MAX_BPS),
                _wftmIn.mul(sl).div(MAX_BPS),
                address(this),
                now
            );

            _processRewardLpTokens(sexWftmLp, sexHelperVault);
        }

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(0, block.number);

        /// @dev Harvest must return the amount of want increased
        return 0;
    }

    /// ===== Internal Helper Functions =====

    function _depositForIntoHelper(
        ISettV4h _helperVault,
        address _recipient,
        uint256 _amount
    ) internal returns (uint256) {
        uint256 helperVaultBefore = _helperVault.balanceOf(_recipient);

        _helperVault.depositFor(_recipient, _amount);

        uint256 helperVaultAfter = _helperVault.balanceOf(_recipient);

        return helperVaultAfter.sub(helperVaultBefore);
    }

    /// @dev used to manage the governance and strategist fee on earned rewards, make sure to use it to get paid!
    function _processRewardLpTokens(
        IERC20Upgradeable _lpToken,
        ISettV4h _helperVault
    ) internal {
        // Desposit the rest of the LP for the Tree
        uint256 lpBalance = _lpToken.balanceOf(address(this));

        uint256 governanceFee = lpBalance.mul(performanceFeeGovernance).div(
            MAX_FEE
        );

        if (governanceFee > 0) {
            address treasury = IController(controller).rewards();
            uint256 govVaultPositionGained = _depositForIntoHelper(
                _helperVault,
                treasury,
                governanceFee
            );

            emit PerformanceFeeGovernance(
                treasury,
                address(_helperVault),
                govVaultPositionGained,
                block.number,
                block.timestamp
            );
        }

        uint256 strategistFee = lpBalance.mul(performanceFeeStrategist).div(
            MAX_FEE
        );

        if (strategistFee > 0) {
            uint256 strategistVaultPositionGained = _depositForIntoHelper(
                _helperVault,
                strategist,
                strategistFee
            );

            emit PerformanceFeeStrategist(
                strategist,
                address(_helperVault),
                strategistVaultPositionGained,
                block.number,
                block.timestamp
            );
        }

        uint256 lpToTree = lpBalance.sub(governanceFee).sub(strategistFee);

        uint256 treeVaultPositionGained = _depositForIntoHelper(
            _helperVault,
            badgerTree,
            lpToTree
        );

        emit TreeDistribution(
            address(_helperVault),
            treeVaultPositionGained,
            block.number,
            block.timestamp
        );
    }

    function _swapExactTokensForTokens(
        address _router,
        uint256 _amountIn,
        route memory _route
    ) internal {
        route[] memory routeArray = new route[](1);
        routeArray[0] = _route;
        IBaseV1Router01(_router).swapExactTokensForTokens(
            _amountIn,
            0,
            routeArray,
            address(this),
            block.timestamp
        );
    }
}
