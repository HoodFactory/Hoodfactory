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

/// @title HoodStockLaunchpad
/// @notice Stock-paired sibling of HoodLaunchpad. Mechanics are identical —
///         fixed supply, 20/80 split, single-sided token-only liquidity, and a
///         permanently locked LP NFT — but the quote asset is chosen per launch
///         from an owner-controlled whitelist of Robinhood Chain Stock Tokens
///         instead of being fixed to WETH.
/// @dev Deployed alongside HoodLaunchpad, never replacing it. Coins launched by
///      the original launchpad are untouched by this contract.
contract HoodStockLaunchpad is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Coin {
        address creator;
        address pool;
        address quote;
        uint256 lpTokenId;
        uint256 marketTokens;
    }

    /// @notice Whitelisted quote asset and the reference amount that fixes the
    ///         starting price. `referenceAmount` is denominated in the quote
    ///         token's own decimals and prices START_REFERENCE_TOKENS tokens.
    struct QuoteConfig {
        bool allowed;
        uint256 referenceAmount;
    }

    /// @dev Grouped so createCoin stays within the EVM stack limit.
    struct Market {
        address pool;
        uint256 lpTokenId;
        uint256 usedToken;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
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

    /// @notice Token side of the starting price ratio. The quote side is the
    ///         per-asset `referenceAmount` configured by the owner.
    uint256 public constant START_REFERENCE_TOKENS = 10_000_000e18;

    uint160 private constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 private constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    IUniswapV3Factory public immutable v3Factory;
    INonfungiblePositionManager public immutable positionManager;

    address public protocolTreasury;
    /// @notice Ordinary admin-controlled wallet. It is intentionally not a
    ///         vesting contract and provides no automatic claim schedule.
    address public creatorVestingWallet;

    /// @notice Quote assets this launchpad accepts. This is the final gate:
    ///         calling the contract directly cannot bypass it.
    mapping(address quote => QuoteConfig) public quoteConfig;
    address[] public allQuotes;

    mapping(address token => Coin) public coins;
    /// @notice Aggregate claimable per quote asset (dashboard use).
    mapping(address quote => mapping(address account => uint256 amount))
        public claimableFees;
    mapping(address token => mapping(address account => uint256 quoteAmount))
        public claimableQuoteFees;
    mapping(address token => mapping(address account => uint256 tokenAmount))
        public claimableTokenFees;
    address[] public allCoins;

    event CoinCreated(
        address indexed token,
        address indexed creator,
        address indexed pool,
        address quote,
        uint24 fee,
        uint160 initialSqrtPriceX96,
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
        address indexed quote,
        uint256 quoteAmount,
        uint256 tokenAmount
    );
    event FeesClaimed(
        address indexed token,
        address indexed account,
        uint256 quoteAmount,
        uint256 tokenAmount
    );
    event QuoteConfigured(
        address indexed quote,
        bool allowed,
        uint256 referenceAmount
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
    error QuoteNotAllowed();
    error InvalidStartingPrice();

    constructor(
        IUniswapV3Factory v3Factory_,
        INonfungiblePositionManager positionManager_,
        address protocolTreasury_,
        address creatorVestingWallet_,
        address owner_
    ) Ownable(owner_) {
        if (
            address(v3Factory_) == address(0) ||
            address(positionManager_) == address(0) ||
            protocolTreasury_ == address(0) ||
            creatorVestingWallet_ == address(0)
        ) revert ZeroAddress();

        v3Factory = v3Factory_;
        positionManager = positionManager_;
        protocolTreasury = protocolTreasury_;
        creatorVestingWallet = creatorVestingWallet_;
    }

    /// @notice Whitelist a Stock Token and fix the starting price against it.
    /// @param quote Stock Token address, verified off-chain against Blockscout.
    /// @param referenceAmount Quote units (in the quote's own decimals) that
    ///        START_REFERENCE_TOKENS tokens are worth at launch. Zero disables.
    function setQuote(
        address quote,
        bool allowed,
        uint256 referenceAmount
    ) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        if (allowed && referenceAmount == 0) revert ZeroAmount();

        QuoteConfig storage cfg = quoteConfig[quote];
        if (cfg.referenceAmount == 0 && !cfg.allowed) allQuotes.push(quote);
        cfg.allowed = allowed;
        cfg.referenceAmount = referenceAmount;
        emit QuoteConfigured(quote, allowed, referenceAmount);
    }

    function quoteCount() external view returns (uint256) {
        return allQuotes.length;
    }

    /// @notice Create a fixed-supply coin and its permanent V3 market against a
    ///         whitelisted Stock Token.
    /// @dev 20% is transferred to creatorVestingWallet (an ordinary wallet),
    ///      while 80% is deposited token-only into the locked LP NFT. The
    ///      caller pays gas only — no quote asset is ever pulled from them.
    function createCoin(
        string calldata name,
        string calldata symbol,
        address quote
    ) external nonReentrant whenNotPaused returns (address token) {
        QuoteConfig memory cfg = quoteConfig[quote];
        if (!cfg.allowed || cfg.referenceAmount == 0) revert QuoteNotAllowed();

        token = address(new HoodToken(name, symbol, TOTAL_SUPPLY));
        IERC20 launchedToken = IERC20(token);

        launchedToken.safeTransfer(creatorVestingWallet, CREATOR_ALLOCATION);
        emit CreatorAllocation(token, creatorVestingWallet, CREATOR_ALLOCATION);

        Coin storage c = coins[token];
        c.creator = msg.sender;
        c.quote = quote;

        Market memory m =
            _createLockedMarket(token, launchedToken, quote, cfg.referenceAmount);
        c.pool = m.pool;
        c.lpTokenId = m.lpTokenId;
        c.marketTokens = m.usedToken;

        allCoins.push(token);
        emit CoinCreated(
            token,
            msg.sender,
            m.pool,
            quote,
            POOL_FEE,
            m.sqrtPriceX96,
            name,
            symbol
        );
        emit LiquidityLocked(
            token,
            m.pool,
            m.lpTokenId,
            m.usedToken,
            m.tickLower,
            m.tickUpper
        );
    }

    function _createLockedMarket(
        address token,
        IERC20 launchedToken,
        address quote,
        uint256 referenceQuote
    ) private returns (Market memory m) {
        (address token0, address token1) = quote < token
            ? (quote, token)
            : (token, quote);

        if (v3Factory.getPool(token0, token1, POOL_FEE) != address(0)) {
            revert PoolAlreadyExists();
        }
        m.pool = v3Factory.createPool(token0, token1, POOL_FEE);

        bool launchedIsToken0 = token0 == token;
        m.sqrtPriceX96 = _startingSqrtPriceX96(launchedIsToken0, referenceQuote);
        IUniswapV3Pool(m.pool).initialize(m.sqrtPriceX96);

        (m.tickLower, m.tickUpper) = _rangeFor(m.pool, launchedIsToken0);

        uint256 amount0Desired = launchedIsToken0 ? MARKET_SUPPLY : 0;
        uint256 amount1Desired = launchedIsToken0 ? 0 : MARKET_SUPPLY;
        launchedToken.forceApprove(address(positionManager), MARKET_SUPPLY);

        uint256 used0;
        uint256 used1;
        (m.lpTokenId, , used0, used1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: m.tickLower,
                tickUpper: m.tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: (amount0Desired * MINT_MIN_BPS) / BPS,
                amount1Min: (amount1Desired * MINT_MIN_BPS) / BPS,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        launchedToken.forceApprove(address(positionManager), 0);

        m.usedToken = launchedIsToken0 ? used0 : used1;
        if (m.usedToken < (MARKET_SUPPLY * MINT_MIN_BPS) / BPS) {
            revert LiquidityMintFailed();
        }

        // Any negligible V3 rounding dust is burned; it can never be swept.
        uint256 dust = MARKET_SUPPLY - m.usedToken;
        if (dust > 0) HoodToken(token).burn(dust);
    }

    /// @dev Single-sided range starting at the freshly initialized price, on
    ///      whichever side of it the launched token sits.
    function _rangeFor(
        address pool,
        bool launchedIsToken0
    ) private view returns (int24 tickLower, int24 tickUpper) {
        (, int24 currentTick, , , , , ) = IUniswapV3Pool(pool).slot0();
        int24 spacing = v3Factory.feeAmountTickSpacing(POOL_FEE);
        if (spacing <= 0 || RANGE_WIDTH % spacing != 0) {
            revert InvalidTickSpacing();
        }

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
    }

    /// @dev Starting price is START_REFERENCE_TOKENS tokens per the quote's
    ///      configured referenceAmount. Both sides are raw units, so a quote
    ///      with 6 or 8 decimals is handled without a separate scaling factor.
    function _startingSqrtPriceX96(
        bool launchedIsToken0,
        uint256 referenceQuote
    ) private pure returns (uint160 sqrtPriceX96) {
        uint256 amount0 = launchedIsToken0
            ? START_REFERENCE_TOKENS
            : referenceQuote;
        uint256 amount1 = launchedIsToken0
            ? referenceQuote
            : START_REFERENCE_TOKENS;
        sqrtPriceX96 = uint160(
            Math.sqrt(Math.mulDiv(amount1, 1 << 96, amount0)) << 48
        );
        if (sqrtPriceX96 <= MIN_SQRT_RATIO || sqrtPriceX96 >= MAX_SQRT_RATIO) {
            revert InvalidStartingPrice();
        }
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
    ) external nonReentrant returns (uint256 quoteAmount, uint256 tokenAmount) {
        return _collectPoolFees(token);
    }

    function _collectPoolFees(
        address token
    ) private returns (uint256 quoteAmount, uint256 tokenAmount) {
        Coin storage c = coins[token];
        if (c.creator == address(0)) revert UnknownCoin();
        address quote = c.quote;

        (uint256 a0, uint256 a1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: c.lpTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        (quoteAmount, tokenAmount) = quote < token ? (a0, a1) : (a1, a0);

        if (quoteAmount > 0) {
            uint256 creatorAmount =
                (quoteAmount * CREATOR_FEE_SHARE_BPS) / BPS;
            claimableFees[quote][c.creator] += creatorAmount;
            claimableFees[quote][protocolTreasury] +=
                quoteAmount - creatorAmount;
            claimableQuoteFees[token][c.creator] += creatorAmount;
            claimableQuoteFees[token][protocolTreasury] +=
                quoteAmount - creatorAmount;
        }
        if (tokenAmount > 0) {
            uint256 creatorTokenAmount =
                (tokenAmount * CREATOR_FEE_SHARE_BPS) / BPS;
            claimableTokenFees[token][c.creator] += creatorTokenAmount;
            claimableTokenFees[token][protocolTreasury] +=
                tokenAmount - creatorTokenAmount;
        }
        emit PoolFeesCollected(token, quote, quoteAmount, tokenAmount);
    }

    function claimFees(
        address token
    ) external nonReentrant returns (uint256 quoteAmount, uint256 tokenAmount) {
        if (coins[token].creator == address(0)) revert UnknownCoin();
        return _claimFees(token, msg.sender);
    }

    /// @notice Creator harvests the LP and claims both fee assets in one tx.
    function collectAndClaimCreatorFees(
        address token
    ) external nonReentrant returns (uint256 quoteAmount, uint256 tokenAmount) {
        Coin storage c = coins[token];
        if (c.creator != msg.sender) revert UnknownCoin();
        _collectPoolFees(token);
        return _claimFees(token, msg.sender);
    }

    function _claimFees(
        address token,
        address account
    ) private returns (uint256 quoteAmount, uint256 tokenAmount) {
        address quote = coins[token].quote;
        quoteAmount = claimableQuoteFees[token][account];
        tokenAmount = claimableTokenFees[token][account];
        if (quoteAmount == 0 && tokenAmount == 0) revert ZeroAmount();

        claimableQuoteFees[token][account] = 0;
        claimableFees[quote][account] -= quoteAmount;
        claimableTokenFees[token][account] = 0;
        if (quoteAmount > 0) IERC20(quote).safeTransfer(account, quoteAmount);
        if (tokenAmount > 0) IERC20(token).safeTransfer(account, tokenAmount);
        emit FeesClaimed(token, account, quoteAmount, tokenAmount);
    }

    function pendingCreatorFees(
        address token
    ) external view returns (uint256 quoteAmount, uint256 tokenAmount) {
        address creator = coins[token].creator;
        if (creator == address(0)) revert UnknownCoin();
        return (
            claimableQuoteFees[token][creator],
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
