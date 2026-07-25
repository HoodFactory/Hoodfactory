const hre = require("hardhat");

// Testnet helper: create and seed a WETH/<stock> Uniswap V3 pool so the
// ETH->stock->token auto-route is testable. Real Robinhood Chain stock tokens
// already have ETH/USDG liquidity on mainnet; the testnet mocks do not, so this
// stands one up. Symbol via STOCK env (default mAAPL). Never used on mainnet.

const WETH = "0x33e4191705c386532ba27cBF171Db86919200B94";
const FACTORY = "0xBC7832D7B3A1D16922ddB0BeF501CCC9157CdDb7";
const NPM = "0x11a81C212fb97AF8c89De811F3530Db15592faf2";
const FEE = 10000;
const SPACING = 200;
const MIN_TICK = -887200, MAX_TICK = 887200;

const bigintSqrt = (v) => {
  if (v < 2n) return v;
  let x = v, y = (x + 1n) / 2n;
  while (y < x) { x = y; y = (x + v / x) / 2n; }
  return x;
};

async function main() {
  const catalog = require("../../config/stockTokens.json");
  const symbol = process.env.STOCK || "mAAPL";
  const entry = (catalog.networks["46630"].tokens || []).find((t) => t.symbol === symbol);
  if (!entry || !/^0x[0-9a-fA-F]{40}$/.test(entry.address || "")) {
    throw new Error(`${symbol} has no deployed testnet address in config/stockTokens.json`);
  }
  const stock = entry.address;

  const [signer] = await hre.ethers.getSigners();
  const eth = hre.ethers;
  console.log("Deployer:", signer.address, "| stock:", symbol, stock);

  const weth = new eth.Contract(WETH, [
    "function deposit() payable",
    "function approve(address,uint256) returns (bool)",
    "function balanceOf(address) view returns (uint256)"
  ], signer);
  const stockC = new eth.Contract(stock, [
    "function mint(address,uint256)",
    "function approve(address,uint256) returns (bool)",
    "function balanceOf(address) view returns (uint256)"
  ], signer);
  const factory = new eth.Contract(FACTORY, [
    "function getPool(address,address,uint24) view returns (address)",
    "function createPool(address,address,uint24) returns (address)"
  ], signer);
  const pm = new eth.Contract(NPM, [
    "function mint((address token0,address token1,uint24 fee,int24 tickLower,int24 tickUpper,uint256 amount0Desired,uint256 amount1Desired,uint256 amount0Min,uint256 amount1Min,address recipient,uint256 deadline)) payable returns (uint256,uint128,uint256,uint256)"
  ], signer);
  const pool = (addr) => new eth.Contract(addr, [
    "function initialize(uint160)",
    "function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)"
  ], signer);

  // Amounts: 0.02 WETH + 0.2 stock (testnet price ~ 0.1 WETH per share).
  const wethAmt = eth.parseEther("0.02");
  const stockAmt = eth.parseUnits("0.2", 18);

  if (await weth.balanceOf(signer.address) < wethAmt) {
    console.log("Wrapping 0.02 ETH -> WETH...");
    await (await weth.deposit({ value: wethAmt })).wait();
  }
  console.log("Minting", eth.formatUnits(stockAmt, 18), symbol, "...");
  await (await stockC.mint(signer.address, stockAmt)).wait();

  let poolAddr = await factory.getPool(WETH, stock, FEE);
  if (poolAddr === eth.ZeroAddress) {
    console.log("Creating WETH/" + symbol + " pool...");
    await (await factory.createPool(WETH, stock, FEE)).wait();
    poolAddr = await factory.getPool(WETH, stock, FEE);
  }
  console.log("Pool:", poolAddr);

  const token0 = WETH.toLowerCase() < stock.toLowerCase() ? WETH : stock;
  const token1 = token0 === WETH ? stock : WETH;
  // price = token1 per token0. Target 1 stock = 0.1 WETH.
  const [a0, a1] = token0 === WETH
    ? [eth.parseEther("0.1"), eth.parseUnits("1", 18)]   // WETH per 1 stock
    : [eth.parseUnits("1", 18), eth.parseEther("0.1")];
  const sqrtPriceX96 = eth.toBigInt(bigintSqrt((a1 * (1n << 96n) * (1n << 96n)) / a0)) ;

  const [slot0Price] = await pool(poolAddr).slot0();
  if (slot0Price === 0n) {
    console.log("Initializing price...");
    await (await pool(poolAddr).initialize(sqrtPriceX96)).wait();
  }

  console.log("Approving position manager...");
  await (await weth.approve(NPM, wethAmt)).wait();
  await (await stockC.approve(NPM, stockAmt)).wait();

  const amount0Desired = token0 === WETH ? wethAmt : stockAmt;
  const amount1Desired = token0 === WETH ? stockAmt : wethAmt;
  console.log("Adding full-range liquidity...");
  const tx = await pm.mint({
    token0, token1, fee: FEE,
    tickLower: MIN_TICK, tickUpper: MAX_TICK,
    amount0Desired, amount1Desired, amount0Min: 0, amount1Min: 0,
    recipient: signer.address, deadline: Math.floor(Date.now() / 1000) + 600
  });
  const rc = await tx.wait();
  console.log("Liquidity added. tx:", rc.hash);
  console.log(`WETH/${symbol} pool seeded — ETH route is now testable.`);
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
