// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../interfaces/IUniswapV3.sol";

/// Test doubles for the Uniswap V3 infrastructure on Robinhood Chain.
/// Only used by the hardhat test suite; never deployed.

contract MockWETH9 is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "eth send failed");
    }

    /// Test helper: mint unbacked WETH (back it with deposit() when a test
    /// later needs withdraw() to succeed).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    receive() external payable {}
}

interface ISwapCallback {
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    address public immutable weth;
    uint160 public sqrtPriceX96;

    constructor(address token0_, address token1_, address weth_) {
        token0 = token0_;
        token1 = token1_;
        weth = weth_;
    }

    function initialize(uint160 sqrtPriceX96_) external {
        require(sqrtPriceX96 == 0, "already init");
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    /// Naive swap implementation kept for generic local pool tests. Uses the
    /// launch reference price (10M tokens per 0.007 WETH) minus the 1% pool fee.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        address input = zeroForOne ? token0 : token1;
        address output = zeroForOne ? token1 : token0;
        uint256 inputAmount = uint256(amountSpecified);
        bool inputIsWeth = input == weth;
        uint256 outputAmount = inputIsWeth
            ? (inputAmount * 10_000_000e18 * 99) / (7e15 * 100)
            : (inputAmount * 7e15 * 99) / (10_000_000e18 * 100);
        if (zeroForOne) {
            (amount0, amount1) = (int256(inputAmount), -int256(outputAmount));
        } else {
            (amount0, amount1) = (-int256(outputAmount), int256(inputAmount));
        }
        IERC20(output).transfer(recipient, outputAmount);
        ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
    }
}

contract MockV3Factory {
    address public immutable weth;
    mapping(bytes32 => address) public pools;

    constructor(address weth_) {
        weth = weth_;
    }

    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address) {
        return pools[keccak256(abi.encode(tokenA, tokenB, fee))];
    }

    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool) {
        pool = address(new MockV3Pool(tokenA, tokenB, weth));
        // Real UniswapV3Factory answers getPool for both argument orders.
        pools[keccak256(abi.encode(tokenA, tokenB, fee))] = pool;
        pools[keccak256(abi.encode(tokenB, tokenA, fee))] = pool;
    }

    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 200;
    }
}

contract MockPositionManager {
    uint256 public nextId = 1;
    mapping(uint256 => address) public ownerOf;
    uint256 public lastAmount0;
    uint256 public lastAmount1;
    address public lastToken0;
    address public lastToken1;
    int24 public lastTickLower;
    int24 public lastTickUpper;
    uint256 public collect0;
    uint256 public collect1;
    address public collectToken0;
    address public collectToken1;

    function mint(
        INonfungiblePositionManager.MintParams calldata p
    )
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // Pull the full desired amounts, like a fresh full-range mint would
        // (minus negligible rounding) when the price matches the ratio.
        IERC20(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired);
        IERC20(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired);
        lastToken0 = p.token0;
        lastToken1 = p.token1;
        lastTickLower = p.tickLower;
        lastTickUpper = p.tickUpper;
        lastAmount0 = p.amount0Desired;
        lastAmount1 = p.amount1Desired;
        tokenId = nextId++;
        ownerOf[tokenId] = p.recipient;
        return (tokenId, 1e18, p.amount0Desired, p.amount1Desired);
    }

    /// Test helper: set the fee amounts the next collect() will pay out of
    /// this mock's own balance (fund it in the test first).
    function setCollectAmounts(
        address token0_,
        address token1_,
        uint256 amount0,
        uint256 amount1
    ) external {
        collectToken0 = token0_;
        collectToken1 = token1_;
        collect0 = amount0;
        collect1 = amount1;
    }

    function collect(
        INonfungiblePositionManager.CollectParams calldata p
    ) external payable returns (uint256 amount0, uint256 amount1) {
        amount0 = collect0;
        amount1 = collect1;
        if (amount0 > 0) IERC20(collectToken0).transfer(p.recipient, amount0);
        if (amount1 > 0) IERC20(collectToken1).transfer(p.recipient, amount1);
        collect0 = 0;
        collect1 = 0;
    }
}
