// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {BaseTokenizedStrategy} from "@tokenized-strategy/BaseTokenizedStrategy.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniswapV3Pool} from "@uniswap/interfaces/IUniswapV3Pool.sol";

import {UniswapHelperViews} from "./libraries/UniswapHelperViews.sol";
// Liquidity calculations
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
// Pool tick calculations
import {TickMath} from "./libraries/TickMath.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specifc storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be udpated post deployement will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement and onlyKeepers modifiers

contract LPStrategy is BaseTokenizedStrategy {
    using SafeERC20 for ERC20;

    address public pool;
    address public otherPoolToken;
    int24 public ticksFromCurrent = 0;
    int24 public minTick;
    int24 public maxTick;

    uint256 public epochStartedAt;
    uint256 public epochDuration;

    address public vault;
    uint256 public depositLimit;

    constructor(
        address _asset,
        string memory _name,
        address _vault,
        uint256 _depositLimit
    ) BaseTokenizedStrategy(_asset, _name) {
        vault = _vault;
        depositLimit = _depositLimit;
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // Do nothing since we only deploy funds on reports
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // TODO: allow withdraws only between epochs
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        uint256 _currentEpochStartedAt = epochStartedAt;
        if (_currentEpochStartedAt == 0) {
            // There is no running epoch. Start one
            // NOTE: we save assets just before
            _totalAssets = ERC20(asset).balanceOf(address(this));
            // TODO: request hedge (and substract payment from _totalAssets)
            createLP();
            return _totalAssets;
        }

        // require that it's the right time to close the epoch
        require(_shouldClosePosition(), "epoch-live"); // dev: epoch is running

        // An epoch is running and it's time to close
        (uint128 liquidity, , , , ) = _positionInfo();
        burnLP(liquidity);
        _totalAssets = ERC20(asset).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed poisition maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    function _tend(uint256 _totalIdle) internal override {}
    */

    /**
     * @notice Returns weather or not tend() should be called by a keeper.
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function tendTrigger() public view override returns (bool) {}
    */

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overriden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
     */
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        if (_owner != vault) {
            return 0;
        }

        uint256 _depositLimit = depositLimit;

        if (_depositLimit == type(uint256).max) {
            return type(uint256).max;
        }

        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        return _totalAssets >= _depositLimit ? 0 : _depositLimit - _totalAssets;
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overriden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     *
     */
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        // only allow idle as withdrawable
        return TokenizedStrategy.totalIdle();
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // TODO: Implement
    }

    /*
     * @notice
     *  Function used internally to open the LP position in the uni v3 pool:
     *      - calculates the ticks to provide liquidity into
     *      - calculates the liquidity amount to provide based on the ticks
     *      and amounts to invest
     *      - calls the mint function in the uni v3 pool
     * @return balance of tokens in the LP (invested amounts)
     */
    function createLP() internal returns (uint256, uint256) {
        IUniswapV3Pool _pool = IUniswapV3Pool(pool);
        // Get the current state of the pool
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = _pool.slot0();
        // Space between ticks for this pool
        int24 _tickSpacing = _pool.tickSpacing();
        // Current tick must be referenced as a multiple of tickSpacing
        int24 _currentTick = (tick / _tickSpacing) * _tickSpacing;
        // Gas savings for # of ticks to LP
        int24 _ticksFromCurrent = int24(ticksFromCurrent);
        // Minimum tick to enter
        // we fix to the tick just above the current tick to ensure we provide single side
        int24 _minTick = _currentTick - (_tickSpacing * _ticksFromCurrent);
        // Maximum tick to enter
        int24 _maxTick = _currentTick +
            (_tickSpacing * (_ticksFromCurrent + 1));

        // Set the state variables
        minTick = _minTick;
        maxTick = _maxTick;

        uint256 amount0;
        uint256 amount1;

        // Make sure tokens are in order
        if (asset < otherPoolToken) {
            amount0 = balanceOfAsset();
            // expected to be 0 in single sided
            amount1 = balanceOfOtherPoolToken();
        } else {
            // expected to be 0 in single sided
            amount0 = balanceOfOtherPoolToken();
            amount1 = balanceOfAsset();
        }

        // Calculate the amount of liquidity the joint can provided based on current situation
        // and amount of tokens available
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(_minTick),
            TickMath.getSqrtRatioAtTick(_maxTick),
            amount0,
            amount1
        );

        // Mint the LP position - we are not yet in the LP, needs to go through the mint
        // callback first
        _pool.mint(address(this), _minTick, _maxTick, liquidityAmount, "");

        // After executing the mint callback, calculate the invested amounts
        return balanceOfTokensInLP();
    }

    /*
     * @notice
     *  Function used internally to close the LP position in the uni v3 pool:
     *      - burns the LP liquidity specified amount
     *      - collects all pending rewards
     *      - re-sets the active position min and max tick to 0
     * @param amount, amount of liquidity to burn
     */
    function burnLP(uint256 _amount) internal {
        _burnAndCollect(_amount, minTick, maxTick);
        // If entire position is closed, re-set the min and max ticks
        (uint128 liquidity, , , , ) = _positionInfo();
        if (liquidity == 0) {
            minTick = 0;
            maxTick = 0;
        }
    }

    /*
     * @notice
     *  Function called by the uniswap pool when minting the LP position (providing liquidity),
     * instead of approving and sending the tokens, uniV3 calls the callback imoplementation
     * on the caller contract
     * @param amount0Owed, amount of token0 to send
     * @param amount1Owed, amount of token1 to send
     * @param data, additional calldata
     */
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        IUniswapV3Pool _pool = IUniswapV3Pool(pool);
        // Only the pool can use this function
        require(msg.sender == address(_pool)); // dev: callback only called by pool
        // Send the required funds to the pool
        ERC20(_pool.token0()).safeTransfer(address(_pool), amount0Owed);
        ERC20(_pool.token1()).safeTransfer(address(_pool), amount1Owed);
    }

    function balanceOfAsset() public returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    function balanceOfOtherPoolToken() public returns (uint256) {
        return ERC20(otherPoolToken).balanceOf(address(this));
    }

    /*
     * @notice
     *  Function returning the current balance of each token in the LP position taking
     * the new level of reserves into account
     * @return _balanceAsset, balance of tokenAsset in the LP position
     * @return _balanceOtherToken, balance of tokenOtherToken in the LP position
     */
    function balanceOfTokensInLP()
        public
        view
        returns (uint256 _balanceAsset, uint256 _balanceOtherToken)
    {
        // Get the current pool status
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        // Get the current position status
        (uint128 liquidity, , , , ) = _positionInfo();

        // Use Uniswap libraries to calculate the token0 and token1 balances for the
        // provided ticks and liquidity amount
        (uint256 amount0, uint256 amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(minTick),
                TickMath.getSqrtRatioAtTick(maxTick),
                liquidity
            );
        // uniswap orders token0 and token1 based on alphabetical order
        return asset < otherPoolToken ? (amount0, amount1) : (amount1, amount0);
    }

    /*
     * @notice
     *  Function used internally to retrieve the details of the joint's LP position:
     * - the amount of liquidity owned by this position
     * - fee growth per unit of liquidity as of the last update to liquidity or fees owed
     * - the fees owed to the position owner in token0/token1
     * @return PositionInfo struct containing the position details
     */
    function _positionInfo()
        private
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        bytes32 key = keccak256(
            abi.encodePacked(address(this), minTick, maxTick)
        );
        return IUniswapV3Pool(pool).positions(key);
    }

    /*
     * @notice
     *  Function available internally to burn the LP amount specified, for position
     * defined by minTick and maxTick specified and collect the owed tokens
     * @param _amount, amount of liquidity to burn
     * @param _minTick, lower limit of position
     * @param _maxTick, upper limit of position
     */
    function _burnAndCollect(
        uint256 _amount,
        int24 _minTick,
        int24 _maxTick
    ) internal {
        IUniswapV3Pool _pool = IUniswapV3Pool(pool);
        _pool.burn(_minTick, _maxTick, uint128(_amount));
        _pool.collect(
            address(this),
            _minTick,
            _maxTick,
            type(uint128).max,
            type(uint128).max
        );
    }

    function _shouldClosePosition() internal returns (bool) {
        uint256 _currentEpochStartedAt = epochStartedAt;

        if (_currentEpochStartedAt == 0) {
            return false;
        }

        if (_currentEpochStartedAt + epochDuration <= block.timestamp) {
            // An epoch is running and it's time to close
            return true;
        }

        IUniswapV3Pool _pool = IUniswapV3Pool(pool);
        // The Epoch is running. Is it in danger?
        // Get the current state of the pool
        (uint160 sqrtPriceX96, int24 tick, , , , , ) = _pool.slot0();
        // Space between ticks for this pool
        int24 _tickSpacing = _pool.tickSpacing();
        // Current tick must be referenced as a multiple of tickSpacing
        int24 _currentTick = (tick / _tickSpacing) * _tickSpacing;
        if (_currentTick >= maxTick) {
            // The price crossed our range and we are out of range. Time to close the position
            return true;
        }

        return false;
    }
}
