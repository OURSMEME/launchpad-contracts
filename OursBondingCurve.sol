// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OursBondingCurveMath} from "./libraries/OursBondingCurveMath.sol";
import {IOursSnipeTax} from "./interfaces/IOursSnipeTax.sol";
import {IOursLaunchFactoryGraduation} from "./interfaces/ILaunchpadGraduation.sol";
import {OursFeeAccrual} from "./revenue/integration/OursFeeAccrual.sol";
import {OursProjectRegistry} from "./revenue/OursProjectRegistry.sol";
/// @notice Curve reserves exclude versioned revenue; graduation leaves unpaid fees here.
contract OursBondingCurve is OursFeeAccrual {
    using SafeERC20 for IERC20;
    uint256 private constant BASIS_POINTS = 10000;
    error CurveGraduated(); error ZeroAmount(); error ZeroAddress(); error NotFactory();
    error AlreadyInitialized(); error NotInitialized(); error InvalidLaunchEconomics();
    error SlippageExceeded(uint256 actual,uint256 minimum); error TransferFailed();
    error NativeValueMismatch(uint256 supplied,uint256 expected); error UnexpectedNativeValue();
    error AlreadyGraduated(); error NotReadyToGraduate(); error InvalidFeePolicy();
    event CurveBuy(address indexed buyer,address indexed recipient,uint256 quoteIn,uint256 tokensOut,uint256 fee,uint256 tax);
    event CurveSell(address indexed seller,address indexed recipient,uint256 tokensIn,uint256 quoteOut,uint256 fee,uint256 tax);
    event CurveBuyRefunded(address indexed buyer,uint256 refund);
    event CurveCompleted(address recipient,uint256 quoteOut,uint256 tokenOut);
    event Initialized(address token); event AutoGraduationFailed(address indexed token,uint256 gasRemaining);
    event SnipeTaxExempted(address indexed account); event SnipeTaxCharged(address indexed recipient,uint256 amount);
    address public token;
    address public immutable pairToken;
    address public immutable factory;
    uint256 public immutable phantomQuote;
    uint256 public immutable feeBps;
    uint256 public constant creatorTaxBps = 0;
    uint256 public immutable graduationThreshold;
    uint256 public trackedQuote;
    uint256 public trackedTokens;
    bool public graduated;
    uint256 public reservedTokens;
    uint256 public launchSupply;
    uint256 public launchedAt;
    uint256 public snipeTaxStartBps;
    uint256 public snipeTaxSeconds;
    mapping(address => bool) public snipeTaxExempt;
    modifier onlyFactory(){if(msg.sender!=factory)revert NotFactory();_;}
    modifier onlyInitialized(){if(token==address(0))revert NotInitialized();_;}
    constructor(address quote,address factory_,OursProjectRegistry registry,uint256 phantom,uint256 fee,uint256 threshold)
        OursFeeAccrual(registry) {
        if(factory_==address(0)||address(registry)==address(0))revert ZeroAddress();
        if(fee>1000||phantom==0||threshold==0)revert InvalidFeePolicy();
        pairToken=quote;factory=factory_;phantomQuote=phantom;feeBps=fee;graduationThreshold=threshold;
    }
    function quoteFeeBalance() external view returns(uint256){return reservedRevenue[pairToken];}
    function _accrueFees(uint256 fee,uint256 tax) private {
        if(tax!=0)revert InvalidFeePolicy();
        if(fee!=0)_accrueRevenue(token,pairToken,fee);
    }
    function _beforeRevenueSweep(address asset,uint256 amount) internal override {
        if(asset!=pairToken)revert InvalidFeePolicy();
        trackedQuote-=amount;
    }
    // Intentionally not nonReentrant: a threshold-crossing buy can call Factory.graduate.
    function graduate(address recipient) external onlyFactory returns(uint256 quoteOut,uint256 tokenOut){
        if(graduated)revert AlreadyGraduated();if(recipient==address(0))revert ZeroAddress();
        if(!readyToGraduate())revert NotReadyToGraduate();graduated=true;
        quoteOut=realQuoteReserve();trackedQuote-=quoteOut;
        tokenOut=trackedTokens;trackedTokens=0;
        if(quoteOut!=0)_sendQuote(recipient,quoteOut);
        if(tokenOut!=0)IERC20(token).safeTransfer(recipient,tokenOut);
        emit CurveCompleted(recipient,quoteOut,tokenOut);
    }
    function isNativeQuote() public view returns (bool) {
        return pairToken == address(0);
    }

    function initialize(address token_) external onlyFactory {
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;

        uint256 supply = IERC20(token_).totalSupply();
        uint256 reserved = Math.mulDiv(supply, phantomQuote, phantomQuote + graduationThreshold);
        // A launch whose allocation rounds away has nothing to seed its pool
        // with, and its final buy would revert against an empty token side.
        // Rejecting the config here fails at launch rather than at graduation.
        if (reserved == 0 || reserved >= supply) revert InvalidLaunchEconomics();
        reservedTokens = reserved;
        launchSupply = supply;
        launchedAt = block.timestamp;
        snipeTaxStartBps = IOursSnipeTax(factory).snipeTaxStartBps();
        snipeTaxSeconds = IOursSnipeTax(factory).snipeTaxSeconds();
        // The allocation the curve actually received, which is the whole
        // supply: the token mints to this curve in its own constructor.
        trackedTokens = IERC20(token_).balanceOf(address(this));

        emit Initialized(token_);
    }

    function sellableTokens() public view returns (uint256) {
        uint256 tracked = trackedTokens;
        return tracked > reservedTokens ? tracked - reservedTokens : 0;
    }

    function currentSnipeTaxBps(address recipient) public view returns (uint256) {
        if (snipeTaxExempt[recipient]) return 0;
        uint256 startBps = snipeTaxStartBps;
        if (startBps == 0) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        uint256 window = snipeTaxSeconds;
        if (elapsed >= window) return 0;
        return startBps >> ((elapsed * 14) / window);
    }

    function exemptFromSnipeTax(address account) external onlyFactory {
        snipeTaxExempt[account] = true;
        emit SnipeTaxExempted(account);
    }

    function getReserves() public view returns (uint256 quoteReserve_, uint256 tokenReserve_) {
        quoteReserve_ = phantomQuote + trackedQuote - reservedRevenue[pairToken];
        tokenReserve_ = trackedTokens;
    }

    function quoteReserve() external view returns (uint256 quoteReserve_) {
        (quoteReserve_,) = getReserves();
    }

    function realQuoteReserve() public view returns (uint256) {
        return trackedQuote - reservedRevenue[pairToken];
    }

    function tokenReserve() external view returns (uint256 tokenReserve_) {
        (, tokenReserve_) = getReserves();
    }

    function readyToGraduate() public view returns (bool) {
        if (graduated) return false;
        return sellableTokens() == 0;
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        nonReentrant
        onlyInitialized
        returns (uint256 tokensOut)
    {
        if (graduated) revert CurveGraduated();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 received = _receiveQuote(quoteIn);
        if (received == 0) revert ZeroAmount();
        // graduate() is deliberately not nonReentrant and the factory's
        // trigger is permissionless, so a quote asset that yields control
        // during transferFrom can drain this curve between the check above
        // and the reserve reads below. Re-checking here rather than relying
        // on the downstream arithmetic to happen to revert.
        if (graduated) revert CurveGraduated();

        uint256 quoteReserveBefore = phantomQuote + trackedQuote - reservedRevenue[pairToken];
        uint256 tokenReserveBefore = trackedTokens;

        // The snipe tax rides the quote leg like the base fee and creator
        // tax, but is bounded so the combined take always nets the buyer at
        // least 1% of their spend and the gross-up below never divides by
        // zero. It deliberately ignores MAX_TOTAL_TRADE_FEE_BPS: a 99% take
        // in the launch second is the entire point. The bound only matters
        // to a nonzero tax, so the common untaxed buy skips it.
        uint256 snipeTaxBps = currentSnipeTaxBps(recipient);
        if (snipeTaxBps != 0) {
            uint256 maxSnipeTaxBps = BASIS_POINTS - feeBps - creatorTaxBps - 100;
            if (snipeTaxBps > maxSnipeTaxBps) snipeTaxBps = maxSnipeTaxBps;
        }

        uint256 spent = received;
        uint256 fee = (spent * feeBps) / BASIS_POINTS;
        uint256 tax = (spent * creatorTaxBps) / BASIS_POINTS;
        uint256 snipeTax = (spent * snipeTaxBps) / BASIS_POINTS;
        tokensOut = OursBondingCurveMath.getAmountOut(
            spent - fee - tax - snipeTax, quoteReserveBefore, tokenReserveBefore, 0
        );

        uint256 sellable = tokenReserveBefore > reservedTokens ? tokenReserveBefore - reservedTokens : 0;
        if (sellable == 0) revert CurveGraduated();

        if (tokensOut > sellable) {
            tokensOut = sellable;
            // Price the clamped fill from the token side, then gross the
            // result back up so the fee legs still come out of the input.
            uint256 net = OursBondingCurveMath.getAmountIn(sellable, quoteReserveBefore, tokenReserveBefore, 0);
            spent = Math.min(
                Math.mulDiv(net, BASIS_POINTS, BASIS_POINTS - feeBps - creatorTaxBps - snipeTaxBps, Math.Rounding.Ceil),
                received
            );
            fee = (spent * feeBps) / BASIS_POINTS;
            tax = (spent * creatorTaxBps) / BASIS_POINTS;
            snipeTax = (spent * snipeTaxBps) / BASIS_POINTS;
        }

        // Price bound rather than quantity bound, so a partial fill honours
        // the caller's terms instead of failing them. Identical to
        // `tokensOut >= minTokensOut` whenever `spent == received`.
        if (spent * minTokensOut > received * tokensOut) revert SlippageExceeded(tokensOut, minTokensOut);

        // The snipe tax joins the base fee bucket, so it splits between
        // platform and project buckets under the current immutable policy version
        // through the ordinary sweep path instead of needing accounting of
        // its own.
        _accrueFees(fee + snipeTax, tax);
        trackedQuote += spent;
        trackedTokens -= tokensOut;
        IERC20(token).safeTransfer(recipient, tokensOut);

        uint256 refund = received - spent;
        if (refund != 0) {
            emit CurveBuyRefunded(msg.sender, refund);
            _sendQuote(msg.sender, refund);
        }

        if (snipeTax != 0) emit SnipeTaxCharged(recipient, snipeTax);
        emit CurveBuy(msg.sender, recipient, spent, tokensOut, fee + snipeTax, tax);
        _tryAutoGraduate();
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 quoteOut)
    {
        if (graduated || readyToGraduate()) revert CurveGraduated();
        if (tokensIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        (uint256 quoteReserveBefore, uint256 tokenReserveBefore) = getReserves();
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        uint256 grossQuoteOut = OursBondingCurveMath.getAmountOut(tokensIn, tokenReserveBefore, quoteReserveBefore, 0);
        uint256 fee = (grossQuoteOut * feeBps) / BASIS_POINTS;
        uint256 tax = (grossQuoteOut * creatorTaxBps) / BASIS_POINTS;
        quoteOut = grossQuoteOut - fee - tax;
        if (quoteOut < minQuoteOut) revert SlippageExceeded(quoteOut, minQuoteOut);

        _accrueFees(fee, tax);
        trackedQuote -= quoteOut;
        trackedTokens += tokensIn;
        _sendQuote(recipient, quoteOut);

        emit CurveSell(msg.sender, recipient, tokensIn, quoteOut, fee, tax);
    }

    function _receiveQuote(uint256 amount) private returns (uint256) {
        if (isNativeQuote()) {
            if (msg.value != amount) revert NativeValueMismatch(msg.value, amount);
            return amount;
        }

        if (msg.value != 0) revert UnexpectedNativeValue();
        IERC20 quote = IERC20(pairToken);
        uint256 balanceBefore = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received=quote.balanceOf(address(this))-balanceBefore;
        if(received!=amount)revert InvalidFeePolicy();
        return received;
    }

    function _sendQuote(address recipient, uint256 amount) private {
        if (isNativeQuote()) {
            (bool sent,) = payable(recipient).call{value: amount}("");
            if (!sent) revert TransferFailed();
            return;
        }
        uint256 before_=IERC20(pairToken).balanceOf(address(this));
        uint256 recipientBefore=IERC20(pairToken).balanceOf(recipient);
        IERC20(pairToken).safeTransfer(recipient, amount);
        if(IERC20(pairToken).balanceOf(address(this))+amount!=before_ || IERC20(pairToken).balanceOf(recipient)!=recipientBefore+amount)revert InvalidFeePolicy();
    }

    function _tryAutoGraduate() private {
        if (readyToGraduate()) {
            try IOursLaunchFactoryGraduation(factory).graduate(token) {}
            catch {
                uint256 gasRemaining = gasleft();
                emit AutoGraduationFailed(token, gasRemaining);
                // Preserve the legacy event and successful buy even if the
                // optional factory notification reverts or consumes its gas.
                // With little gas left, only the legacy event is guaranteed.
                if (gasleft() > 60_000) {
                    try IOursLaunchFactoryGraduation(factory).reportAutoGraduationFailed{gas: 30_000}(token, gasRemaining) {}
                    catch {}
                }
            }
        }
    }
}
