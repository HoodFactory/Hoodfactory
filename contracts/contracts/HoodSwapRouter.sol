// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IUniswapV3Factory,
    IUniswapV3Pool,
    IUniswapV3SwapCallback
} from "./interfaces/IUniswapV3.sol";

interface IHoodLaunchpadView {
    function coins(address token)
        external
        view
        returns (address creator, address pool, uint256 lpTokenId, uint256 marketTokens);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice HOODFACTORY's Robinhood Chain swap entrypoint. Trades execute in the
/// token's Uniswap V3 Token/WETH pool; this router adds a fixed 0.5% platform
/// fee on the ETH side. Users pay and receive native ETH — the router wraps
/// and unwraps WETH internally. Treasury fees accrue in WETH.
contract HoodSwapRouter is IUniswapV3SwapCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant PLATFORM_FEE_BPS = 50; // 0.5%
    uint256 public constant POOL_FEE_BPS = 100; // Uniswap V3 pool tier: 1%
    uint24 public constant POOL_FEE = 10_000;
    uint160 private constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
    uint160 private constant MAX_SQRT_RATIO_MINUS_ONE =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    IERC20 public immutable weth;
    IHoodLaunchpadView public immutable launchpad;
    IUniswapV3Factory public immutable v3Factory;
    address public immutable protocolTreasury;

    address private activePool;
    address private activePayer;
    address private activeInput;

    event SwapExecuted(
        address indexed sender,
        address indexed token,
        bool indexed buy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 platformFee
    );

    error InvalidMarket();
    error InvalidAmount();
    error SlippageExceeded();
    error InvalidCallback();
    error Expired();
    error WrongEthAmount();
    error EthTransferFailed();
    error QuoteResult(uint256 amountOut);

    constructor(
        IERC20 weth_,
        IHoodLaunchpadView launchpad_,
        IUniswapV3Factory v3Factory_,
        address protocolTreasury_
    ) {
        if (
            address(weth_) == address(0) ||
            address(launchpad_) == address(0) ||
            address(v3Factory_) == address(0) ||
            protocolTreasury_ == address(0)
        ) revert InvalidMarket();
        weth = weth_;
        launchpad = launchpad_;
        v3Factory = v3Factory_;
        protocolTreasury = protocolTreasury_;
    }

    /// @notice Swap native ETH -> token (buy) or token -> native ETH (sell).
    /// @dev Buy: send exactly `amountIn` as msg.value. Sell: approve `token`
    ///      for `amountIn` first; output ETH is unwrapped to `recipient`.
    function swapExactInput(
        address token,
        bool buy,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0 || recipient == address(0)) revert InvalidAmount();
        if (buy ? msg.value != amountIn : msg.value != 0) revert WrongEthAmount();
        (, address pool, , ) = launchpad.coins(token);
        if (
            pool == address(0) ||
            v3Factory.getPool(address(weth), token, POOL_FEE) != pool
        ) revert InvalidMarket();

        address token0 = IUniswapV3Pool(pool).token0();
        address input = buy ? address(weth) : token;
        bool zeroForOne = input == token0;
        uint256 swapAmount = amountIn;
        uint256 platformFee;

        activePool = pool;
        // On buys the router itself holds the freshly wrapped WETH, so the
        // callback pays the pool from the router balance instead of the user.
        activePayer = buy ? address(this) : msg.sender;
        activeInput = input;

        if (buy) {
            IWETH(address(weth)).deposit{value: amountIn}();
            platformFee = (amountIn * PLATFORM_FEE_BPS) / BPS;
            swapAmount = amountIn - platformFee;
            weth.safeTransfer(protocolTreasury, platformFee);
        }

        (int256 amount0, int256 amount1) = IUniswapV3Pool(pool).swap(
            buy ? recipient : address(this),
            zeroForOne,
            int256(swapAmount),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            bytes("")
        );

        activePool = address(0);
        activePayer = address(0);
        activeInput = address(0);

        int256 outputDelta = zeroForOne ? amount1 : amount0;
        amountOut = uint256(-outputDelta);
        if (!buy) {
            platformFee = (amountOut * PLATFORM_FEE_BPS) / BPS;
            amountOut -= platformFee;
            weth.safeTransfer(protocolTreasury, platformFee);
            IWETH(address(weth)).withdraw(amountOut);
            (bool sent, ) = recipient.call{value: amountOut}("");
            if (!sent) revert EthTransferFailed();
        }
        if (amountOut < amountOutMinimum) revert SlippageExceeded();
        emit SwapExecuted(msg.sender, token, buy, amountIn, amountOut, platformFee);
    }

    /// @dev Accept ETH only from WETH withdrawals.
    receive() external payable {
        if (msg.sender != address(weth)) revert InvalidCallback();
    }

    function quoteSpot(
        address token,
        bool buy,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 platformFee) {
        (, address pool, , ) = launchpad.coins(token);
        if (pool == address(0)) revert InvalidMarket();
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(pool).slot0();
        bool inputIsToken0 = (buy ? address(weth) : token) ==
            IUniswapV3Pool(pool).token0();
        uint256 netInput = amountIn;
        if (buy) {
            platformFee = (amountIn * PLATFORM_FEE_BPS) / BPS;
            netInput -= platformFee;
        }
        netInput = (netInput * (BPS - POOL_FEE_BPS)) / BPS;
        if (inputIsToken0) {
            amountOut = Math.mulDiv(netInput, sqrtPriceX96, 1 << 96);
            amountOut = Math.mulDiv(amountOut, sqrtPriceX96, 1 << 96);
        } else {
            amountOut = Math.mulDiv(netInput, 1 << 96, sqrtPriceX96);
            amountOut = Math.mulDiv(amountOut, 1 << 96, sqrtPriceX96);
        }
        if (!buy) {
            platformFee = (amountOut * PLATFORM_FEE_BPS) / BPS;
            amountOut -= platformFee;
        }
    }

    /// @notice Simulates the real V3 swap path, including initialized tick
    /// crossings. Call this with eth_call/staticCall; no tokens are moved.
    function quoteExactInput(
        address token,
        bool buy,
        uint256 amountIn
    ) external nonReentrant returns (uint256 amountOut, uint256 platformFee) {
        if (amountIn == 0) revert InvalidAmount();
        (, address pool, , ) = launchpad.coins(token);
        if (
            pool == address(0) ||
            v3Factory.getPool(address(weth), token, POOL_FEE) != pool
        ) revert InvalidMarket();

        address input = buy ? address(weth) : token;
        bool zeroForOne = input == IUniswapV3Pool(pool).token0();
        uint256 swapAmount = amountIn;
        if (buy) {
            platformFee = (amountIn * PLATFORM_FEE_BPS) / BPS;
            swapAmount -= platformFee;
        }

        activePool = pool;
        activePayer = address(0);
        activeInput = input;
        try IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(swapAmount),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            abi.encode(uint8(1))
        ) returns (int256, int256) {
            revert InvalidCallback();
        } catch (bytes memory reason) {
            activePool = address(0);
            activeInput = address(0);
            if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            assembly ("memory-safe") { amountOut := mload(add(reason, 36)) }
        }
        if (!buy) {
            platformFee = (amountOut * PLATFORM_FEE_BPS) / BPS;
            amountOut -= platformFee;
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        _v3SwapCallback(amount0Delta, amount1Delta, data);
    }

    function _v3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) private {
        if (msg.sender != activePool) {
            revert InvalidCallback();
        }
        if (data.length == 32 && abi.decode(data, (uint8)) == 1) {
            int256 outputDelta = amount0Delta < 0 ? amount0Delta : amount1Delta;
            if (outputDelta >= 0) revert InvalidCallback();
            revert QuoteResult(uint256(-outputDelta));
        }
        if (activePayer == address(0)) revert InvalidCallback();
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        if (activePayer == address(this)) {
            IERC20(activeInput).safeTransfer(msg.sender, owed);
        } else {
            IERC20(activeInput).safeTransferFrom(activePayer, msg.sender, owed);
        }
    }
}
