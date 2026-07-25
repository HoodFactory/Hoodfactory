// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HoodToken} from "./HoodToken.sol";
import {
    IUniswapV3Factory,
    IUniswapV3Pool,
    INonfungiblePositionManager
} from "./interfaces/IUniswapV3.sol";

/// @title HoodLaunchpad
/// @notice Robinhood Chain token factory with instant, permanently locked,
///         single-sided Token/WETH liquidity.
/// @dev There is no bonding curve and no migration. Each token trades on its
///      Uniswap V3 pool from launch. WETH (18 decimals) is the quote asset;
///      native ETH is the gas token on Robinhood Chain.
contract HoodLaunchpad is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Coin {
        address creator;
        address pool;
        uint256 lpTokenId;
        uint256 marketTokens;
    }

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CREATOR_ALLOCATION = 200_000_000e18;
    uint256 public constant MARKET_SUPPLY = 800_000_000e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant MINT_MIN_BPS = 9_900;

    uint24 public constant POOL_FEE = 10_000; // Uniswap V3 1% tier
    int24 public constant RANGE_WIDTH = 120_000;
    uint256 public constant CREATOR_FEE_SHARE_BPS = 5_500;
    uint256 public constant PROTOCOL_FEE_SHARE_BPS = 4_500;

    // Starting FDV: approximately 0.7 ETH (about 2,400 USD at 3,500 USD/ETH).
    uint256 public constant START_REFERENCE_TOKENS = 10_000_000e18;
    uint256 public constant START_REFERENCE_WETH = 7e15; // 0.007 WETH per 10M tokens

    IERC20 public immutable weth;
    IUniswapV3Factory public immutable v3Factory;
    INonfungiblePositionManager public immutable positionManager;

    address public protocolTreasury;
    /// @notice Ordinary admin-controlled wallet. It is intentionally not a
    ///         vesting contract and provides no automatic claim schedule.
    address public creatorVestingWallet;

    mapping(address token => Coin) public coins;
    /// @notice Aggregate WETH claimable across all coins (dashboard use).
    mapping(address account => uint256 wethAmount) public claimableFees;
    mapping(address token => mapping(address account => uint256 wethAmount))
        public claimableWethFees;
    mapping(address token => mapping(address account => uint256 tokenAmount))
        public claimableTokenFees;
    address[] public allCoins;

    event CoinCreated(
        address indexed token,
        address indexed creator,
        address indexed pool,
        string name,
        string symbol
    );
    event CreatorAllocation(
        address indexed token,
        address indexed creatorVestingWallet,
        uint256 amount
    );
    event LiquidityLocked(
        address indexed token,
        address indexed pool,
        uint256 indexed lpTokenId,
        uint256 tokenAmount,
        int24 tickLower,
        int24 tickUpper
    );
    event PoolFeesCollected(
        address indexed token,
        uint256 wethAmount,
        uint256 tokenAmount
    );
    event FeesClaimed(
        address indexed token,
        address indexed account,
        uint256 wethAmount,
        uint256 tokenAmount
    );
    event ProtocolTreasuryUpdated(address treasury);
    event CreatorVestingWalletUpdated(address wallet);

    error UnknownCoin();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidTickSpacing();
    error InvalidRange();
    error PoolAlreadyExists();
    error LiquidityMintFailed();

    constructor(
        IERC20 weth_,
        IUniswapV3Factory v3Factory_,
        INonfungiblePositionManager positionManager_,
        address protocolTreasury_,
        address creatorVestingWallet_,
        address owner_
    ) Ownable(owner_) {
        if (
            address(weth_) == address(0) ||
            address(v3Factory_) == address(0) ||
            address(positionManager_) == address(0) ||
            protocolTreasury_ == address(0) ||
            creatorVestingWallet_ == address(0)
        ) revert ZeroAddress();

        weth = weth_;
        v3Factory = v3Factory_;
        positionManager = positionManager_;
        protocolTreasury = protocolTreasury_;
        creatorVestingWallet = creatorVestingWallet_;

    }

    /// @notice Create a fixed-supply coin and its permanent V3 market.
    /// @dev 20% is transferred to creatorVestingWallet (an ordinary wallet),
    ///      while 80% is deposited token-only into the locked LP NFT.
    function createCoin(
        string calldata name,
        string calldata symbol
    ) external nonReentrant whenNotPaused returns (address token) {
        token = address(new HoodToken(name, symbol, TOTAL_SUPPLY));
        IERC20 launchedToken = IERC20(token);

        launchedToken.safeTransfer(creatorVestingWallet, CREATOR_ALLOCATION);
        emit CreatorAllocation(token, creatorVestingWallet, CREATOR_ALLOCATION);

        Coin storage c = coins[token];
        c.creator = msg.sender;

        (address pool, uint256 lpTokenId, uint256 usedToken, int24 lower, int24 upper) =
            _createLockedMarket(token, launchedToken);
        c.pool = pool;
        c.lpTokenId = lpTokenId;
        c.marketTokens = usedToken;

        allCoins.push(token);
        emit CoinCreated(
            token,
            msg.sender,
            pool,
            name,
            symbol
        );
        emit LiquidityLocked(token, pool, lpTokenId, usedToken, lower, upper);
    }

    function _createLockedMarket(
        address token,
        IERC20 launchedToken
    ) private returns (
        address pool,
        uint256 lpTokenId,
        uint256 usedToken,
        int24 tickLower,
        int24 tickUpper
    ) {
        (address token0, address token1) = address(weth) < token
            ? (address(weth), token)
            : (token, address(weth));

        if (v3Factory.getPool(token0, token1, POOL_FEE) != address(0)) {
            revert PoolAlreadyExists();
        }
        pool = v3Factory.createPool(token0, token1, POOL_FEE);

        uint160 sqrtPriceX96 = _startingSqrtPriceX96(token0 == token);
        IUniswapV3Pool(pool).initialize(sqrtPriceX96);

        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        int24 spacing = v3Factory.feeAmountTickSpacing(POOL_FEE);
        if (spacing <= 0 || RANGE_WIDTH % spacing != 0) {
            revert InvalidTickSpacing();
        }

        bool launchedIsToken0 = token0 == token;
        if (launchedIsToken0) {
            tickLower = _ceilToSpacing(currentTick, spacing);
            tickUpper = tickLower + RANGE_WIDTH;
            if (currentTick > tickLower || tickUpper > 887_200) {
                revert InvalidRange();
            }
        } else {
            tickUpper = _floorToSpacing(currentTick, spacing);
            tickLower = tickUpper - RANGE_WIDTH;
            if (currentTick < tickUpper || tickLower < -887_200) {
                revert InvalidRange();
            }
        }

        uint256 amount0Desired = launchedIsToken0 ? MARKET_SUPPLY : 0;
        uint256 amount1Desired = launchedIsToken0 ? 0 : MARKET_SUPPLY;
        launchedToken.forceApprove(address(positionManager), MARKET_SUPPLY);

        uint256 used0;
        uint256 used1;
        (lpTokenId, , used0, used1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: (amount0Desired * MINT_MIN_BPS) / BPS,
                amount1Min: (amount1Desired * MINT_MIN_BPS) / BPS,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        launchedToken.forceApprove(address(positionManager), 0);

        usedToken = launchedIsToken0 ? used0 : used1;
        if (usedToken < (MARKET_SUPPLY * MINT_MIN_BPS) / BPS) {
            revert LiquidityMintFailed();
        }

        // Any negligible V3 rounding dust is burned; it can never be swept.
        uint256 dust = MARKET_SUPPLY - usedToken;
        if (dust > 0) HoodToken(token).burn(dust);
    }

    /// @dev Starting price is about 0.0000000007 WETH/token (0.7 ETH FDV).
    function _startingSqrtPriceX96(
        bool launchedIsToken0
    ) private pure returns (uint160) {
        uint256 amount0 = launchedIsToken0
            ? START_REFERENCE_TOKENS
            : START_REFERENCE_WETH;
        uint256 amount1 = launchedIsToken0
            ? START_REFERENCE_WETH
            : START_REFERENCE_TOKENS;
        return uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 96, amount0)) << 48);
    }

    function _floorToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function _ceilToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 floor = _floorToSpacing(tick, spacing);
        return floor == tick ? floor : floor + spacing;
    }

    /// @notice Harvest locked LP fees. Both fee assets use the same 55/45 split.
    function collectPoolFees(
        address token
    ) external nonReentrant returns (uint256 wethAmount, uint256 tokenAmount) {
        return _collectPoolFees(token);
    }

    function _collectPoolFees(
        address token
    ) private returns (uint256 wethAmount, uint256 tokenAmount) {
        Coin storage c = coins[token];
        if (c.creator == address(0)) revert UnknownCoin();

        (uint256 a0, uint256 a1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: c.lpTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (wethAmount, tokenAmount) = address(weth) < token
            ? (a0, a1)
            : (a1, a0);

        if (wethAmount > 0) {
            uint256 creatorAmount =
                (wethAmount * CREATOR_FEE_SHARE_BPS) / BPS;
            claimableFees[c.creator] += creatorAmount;
            claimableFees[protocolTreasury] += wethAmount - creatorAmount;
            claimableWethFees[token][c.creator] += creatorAmount;
            claimableWethFees[token][protocolTreasury] +=
                wethAmount - creatorAmount;
        }
        if (tokenAmount > 0) {
            uint256 creatorTokenAmount =
                (tokenAmount * CREATOR_FEE_SHARE_BPS) / BPS;
            claimableTokenFees[token][c.creator] += creatorTokenAmount;
            claimableTokenFees[token][protocolTreasury] +=
                tokenAmount - creatorTokenAmount;
        }
        emit PoolFeesCollected(token, wethAmount, tokenAmount);
    }

    function claimFees(
        address token
    ) external nonReentrant returns (uint256 wethAmount, uint256 tokenAmount) {
        if (coins[token].creator == address(0)) revert UnknownCoin();
        return _claimFees(token, msg.sender);
    }

    /// @notice Creator harvests the LP and claims both fee assets in one tx.
    function collectAndClaimCreatorFees(
        address token
    ) external nonReentrant returns (uint256 wethAmount, uint256 tokenAmount) {
        Coin storage c = coins[token];
        if (c.creator != msg.sender) revert UnknownCoin();
        _collectPoolFees(token);
        return _claimFees(token, msg.sender);
    }

    function _claimFees(
        address token,
        address account
    ) private returns (uint256 wethAmount, uint256 tokenAmount) {
        wethAmount = claimableWethFees[token][account];
        tokenAmount = claimableTokenFees[token][account];
        if (wethAmount == 0 && tokenAmount == 0) revert ZeroAmount();

        claimableWethFees[token][account] = 0;
        claimableFees[account] -= wethAmount;
        claimableTokenFees[token][account] = 0;
        if (wethAmount > 0) weth.safeTransfer(account, wethAmount);
        if (tokenAmount > 0) IERC20(token).safeTransfer(account, tokenAmount);
        emit FeesClaimed(token, account, wethAmount, tokenAmount);
    }

    function pendingCreatorFees(
        address token
    ) external view returns (uint256 wethAmount, uint256 tokenAmount) {
        address creator = coins[token].creator;
        if (creator == address(0)) revert UnknownCoin();
        return (
            claimableWethFees[token][creator],
            claimableTokenFees[token][creator]
        );
    }

    function lpIsLocked(address token) external view returns (bool) {
        Coin storage c = coins[token];
        if (c.creator == address(0) || c.lpTokenId == 0) return false;
        return IERC721(address(positionManager)).ownerOf(c.lpTokenId) == address(this);
    }

    function coinCount() external view returns (uint256) {
        return allCoins.length;
    }

    function setProtocolTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert ZeroAddress();
        protocolTreasury = treasury;
        emit ProtocolTreasuryUpdated(treasury);
    }

    function setCreatorVestingWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        creatorVestingWallet = wallet;
        emit CreatorVestingWalletUpdated(wallet);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
