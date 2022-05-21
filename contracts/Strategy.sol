// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {
    Math
} from "@openzeppelin/contracts/math/Math.sol";
import { StrategyConvexBase,IConvexDeposit,IConvexRewards } from "./StrategyConvexBase.sol";
import { ICurveFi } from "./interfaces/ICurveFi.sol";
import { IUniswapV2Router } from "./interfaces/IUniswapV2Router.sol";
import { IUniV3 } from "./interfaces/IUniV3.sol";
import { IBaseFee } from "./interfaces/IBaseFee.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is StrategyConvexBase {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

     /* ========== STATE VARIABLES ========== */
    // these will likely change across different wants.

    // Curve stuff
    ICurveFi public constant curve =
        ICurveFi(0x98a7F18d4E56Cfe84E3D081B40001B3d5bD3eB8B); // This is our pool specific to this vault.
    ICurveFi internal constant crveth =
        ICurveFi(0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511); // use curve's new CRV-ETH crypto pool to sell our CRV
    ICurveFi internal constant cvxeth =
        ICurveFi(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4); // use curve's new CVX-ETH crypto pool to sell our CVX

    bool public checkEarmark; // this determines if we should check if we need to earmark rewards before harvesting

    // we use these to deposit to our curve pool
    IERC20 internal constant usdc =
        IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant uniswapv3 =
        address(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    uint24 public uniUsdcFee; // this is equal to 0.05%, can change this later if a different path becomes more optimal

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        uint256 _pid,
        string memory _name
    ) public StrategyConvexBase(_vault) {
        // want = Curve LP
        want.approve(address(depositContract), type(uint256).max);
        convexToken.approve(address(cvxeth), type(uint256).max);
        crv.approve(address(crveth), type(uint256).max);
        usdc.approve(address(curve), type(uint256).max);
        weth.approve(uniswapv3, type(uint256).max);
        
        // setup our rewards contract
        pid = _pid; // this is the pool ID on convex, we use this to determine what the rewardsContract address is
        (address lptoken, , , address _rewardsContract, , ) =
            IConvexDeposit(depositContract).poolInfo(_pid);

        // set up our rewardsContract
        rewardsContract = IConvexRewards(_rewardsContract);

        // check that our LP token based on our pid matches our want
        require(address(lptoken) == address(want),"lp != want");

        // set our strategy's name
        stratName = _name;

        // set our uniswap pool fees
        uniUsdcFee = 500;
    }


/* ========== VARIABLE FUNCTIONS ========== */
    // these will likely change across different wants.

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // this claims our CRV, CVX, and any extra tokens like SNX or ANKR. no harm leaving this true even if no extra rewards currently.
        rewardsContract.getReward(address(this), true);

        uint256 crvBalance = crv.balanceOf(address(this));
        uint256 convexBalance = convexToken.balanceOf(address(this));

        uint256 _sendToVoter = crvBalance.mul(keepCRV).div(FEE_DENOMINATOR);
        if (_sendToVoter > 0) {
            crv.safeTransfer(voter, _sendToVoter);
        }
        uint256 crvRemainder = crvBalance.sub(_sendToVoter);

        if (crvRemainder > 0 || convexBalance > 0) {
            _sellCrvAndCvx(crvRemainder, convexBalance);
        }

        // deposit our balance to Curve if we have any
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            curve.add_liquidity([0,usdcBalance], 0);
        }

        // debtOustanding will only be > 0 in the event of revoking or if we need to rebalance from a withdrawal or lowering the debtRatio
        if (_debtOutstanding > 0) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                rewardsContract.withdrawAndUnwrap(
                    Math.min(_stakedBal, _debtOutstanding),
                    claimRewards
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _debtPayment = Math.min(_debtOutstanding, _withdrawnBal);
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets > debt) {
            _profit = assets.sub(debt);
            uint256 _wantBal = balanceOfWant();
            if (_profit.add(_debtPayment) > _wantBal) {
                // this should only be hit following donations to strategy
                liquidateAllPositions();
            }
        }
        // if assets are less than debt, we are in trouble
        else {
            _loss = debt.sub(assets);
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    // Sells our CRV -> WETH and CVX -> WETH on Curve, then WETH -> USDC together on UniV3
    function _sellCrvAndCvx(uint256 _crvAmount, uint256 _convexAmount)
        internal
    {
        if (_convexAmount > 0) {
            cvxeth.exchange(1, 0, _convexAmount, 0, false);
        }
        if (_crvAmount > 0) {
            crveth.exchange(1, 0, _crvAmount, 0, false);
        }

        uint256 _wethBalance = weth.balanceOf(address(this));
        if (_wethBalance > 0) {
            IUniV3(uniswapv3).exactInput(
                IUniV3.ExactInputParams(
                    abi.encodePacked(
                        address(weth),
                        uint24(uniUsdcFee),
                        address(usdc)
                    ),
                    address(this),
                    block.timestamp,
                    _wethBalance,
                    uint256(1)
                )
            );
        }
    }

    // migrate our want token to a new strategy if needed, make sure to check claimRewards first
    // also send over any CRV or CVX that is claimed; for migrations we definitely want to claim
    function prepareMigration(address _newStrategy) internal override {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            rewardsContract.withdrawAndUnwrap(_stakedBal, claimRewards);
        }
        crv.safeTransfer(_newStrategy, crv.balanceOf(address(this)));
        convexToken.safeTransfer(
            _newStrategy,
            convexToken.balanceOf(address(this))
        );
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // only check if we need to earmark on vaults we know are problematic
        if (checkEarmark) {
            // don't harvest if we need to earmark convex rewards
            if (needsEarmarkReward()) {
                return false;
            }
        }

        // harvest if we have a profit to claim at our upper limit without considering gas price
        uint256 claimableProfit = claimableProfitInUsdt();
        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    // we will need to add rewards token here if we have them
    function claimableProfitInUsdt() internal view returns (uint256) {
        // calculations pulled directly from CVX's contract for minting CVX per CRV claimed
        uint256 totalCliffs = 1_000;
        uint256 maxSupply = 100 * 1_000_000 * 1e18; // 100mil
        uint256 reductionPerCliff = 100_000 * 1e18; // 100,000
        uint256 supply = convexToken.totalSupply();
        uint256 mintableCvx;

        uint256 cliff = supply.div(reductionPerCliff);
        uint256 _claimableBal = claimableBalance();
        //mint if below total cliffs
        if (cliff < totalCliffs) {
            //for reduction% take inverse of current cliff
            uint256 reduction = totalCliffs.sub(cliff);
            //reduce
            mintableCvx = _claimableBal.mul(reduction).div(totalCliffs);

            //supply cap check
            uint256 amtTillMax = maxSupply.sub(supply);
            if (mintableCvx > amtTillMax) {
                mintableCvx = amtTillMax;
            }
        }

        address[] memory usd_path = new address[](3);
        usd_path[0] = address(crv);
        usd_path[1] = address(weth);
        usd_path[2] = address(usdc);

        uint256 crvValue;
        if (_claimableBal > 0) {
            uint256[] memory crvSwap =
                IUniswapV2Router(sushiswap).getAmountsOut(
                    _claimableBal,
                    usd_path
                );
            crvValue = crvSwap[crvSwap.length - 1];
        }

        usd_path[0] = address(convexToken);
        uint256 cvxValue;
        if (mintableCvx > 0) {
            uint256[] memory cvxSwap =
                IUniswapV2Router(sushiswap).getAmountsOut(
                    mintableCvx,
                    usd_path
                );
            cvxValue = cvxSwap[cvxSwap.length - 1];
        }

        return crvValue.add(cvxValue);
    }

    // convert our keeper's eth cost into want, we don't need this anymore since we don't use baseStrategy harvestTrigger
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {
        return _ethAmount;
    }

    // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }

    // check if someone needs to earmark rewards on convex before keepers harvest again
    function needsEarmarkReward() public view returns (bool needsEarmark) {
        // check if there is any CRV we need to earmark
        uint256 crvExpiry = rewardsContract.periodFinish();
        if (crvExpiry < block.timestamp) {
            return true;
        }
    }

    /* ========== SETTERS ========== */

    // determine whether we will check if our convex rewards need to be earmarked
    function setCheckEarmark(bool _checkEarmark) external onlyAuthorized {
        checkEarmark = _checkEarmark;
    }

    // set the fee pool we'd like to swap through for CRV on UniV3 (1% = 10_000)
    function setUniFees(
        uint24 _usdcFee
    ) external onlyAuthorized {
        uniUsdcFee = _usdcFee;
    }
}