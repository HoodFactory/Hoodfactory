const { expect } = require("chai");
const { ethers } = require("hardhat");

const T = (n) => ethers.parseUnits(n.toString(), 18);
const TOTAL = T(1_000_000_000);
const CREATOR = T(200_000_000);
const MARKET = T(800_000_000);

// 10,000,000 token = 0.074014679578116336 TSLA (~$24 pada $324.26/lembar),
// sama seperti config/stockTokens.json.
const TSLA_REF = 74_014_679_578_116_336n;

describe("HoodStockLaunchpad — stock-paired single-sided V3", () => {
  let owner, protocol, allocation, alice, bob;
  let weth, stock, factory, posMgr, pad;

  beforeEach(async () => {
    [owner, protocol, allocation, alice, bob] = await ethers.getSigners();
    weth = await (await ethers.getContractFactory("MockWETH9")).deploy();
    stock = await (await ethers.getContractFactory("MockStockToken")).deploy(
      "Mock Tesla", "mTSLA", 18
    );
    factory = await (await ethers.getContractFactory("MockV3Factory")).deploy(weth);
    posMgr = await (await ethers.getContractFactory("MockPositionManager")).deploy();
    pad = await (await ethers.getContractFactory("HoodStockLaunchpad")).deploy(
      factory, posMgr, protocol.address, allocation.address, owner.address
    );
    await pad.setQuote(stock, true, TSLA_REF);
  });

  async function createCoin(quote = stock, creator = alice) {
    const tx = await pad.connect(creator).createCoin("Factory Hood", "FHOOD", quote);
    const receipt = await tx.wait();
    return receipt.logs.find((l) => l.fragment?.name === "CoinCreated").args.token;
  }

  describe("whitelist", () => {
    it("rejects a quote token that was never whitelisted", async () => {
      const rogue = await (await ethers.getContractFactory("MockStockToken")).deploy(
        "Fake Tesla", "TSLA", 18
      );
      await expect(
        pad.connect(alice).createCoin("Rug", "RUG", rogue)
      ).to.be.revertedWithCustomError(pad, "QuoteNotAllowed");
    });

    it("rejects a quote the owner has disabled again", async () => {
      await pad.setQuote(stock, false, TSLA_REF);
      await expect(
        pad.connect(alice).createCoin("Factory Hood", "FHOOD", stock)
      ).to.be.revertedWithCustomError(pad, "QuoteNotAllowed");
    });

    it("only lets the owner change the whitelist", async () => {
      await expect(
        pad.connect(alice).setQuote(stock, true, TSLA_REF)
      ).to.be.revertedWithCustomError(pad, "OwnableUnauthorizedAccount");
    });

    it("refuses a whitelist entry without a starting price", async () => {
      const other = await (await ethers.getContractFactory("MockStockToken")).deploy(
        "Mock Apple", "mAAPL", 18
      );
      await expect(pad.setQuote(other, true, 0)).to.be.revertedWithCustomError(
        pad, "ZeroAmount"
      );
    });

    it("tracks configured quotes without duplicating them", async () => {
      expect(await pad.quoteCount()).to.equal(1n);
      await pad.setQuote(stock, true, TSLA_REF * 2n);
      expect(await pad.quoteCount()).to.equal(1n);
      expect(await pad.allQuotes(0)).to.equal(await stock.getAddress());
    });
  });

  describe("launch", () => {
    it("keeps the same 20/80 split as the WETH launchpad", async () => {
      const token = await createCoin();
      const erc = await ethers.getContractAt("HoodToken", token);
      expect(await erc.totalSupply()).to.equal(TOTAL);
      expect(await erc.balanceOf(allocation.address)).to.equal(CREATOR);
      expect(await erc.balanceOf(posMgr)).to.equal(MARKET);
      expect(await erc.balanceOf(pad)).to.equal(0n);
    });

    it("never pulls the quote asset from the creator", async () => {
      await stock.mint(alice.address, T(1000));
      const before = await stock.balanceOf(alice.address);
      await createCoin();
      expect(await stock.balanceOf(alice.address)).to.equal(before);
      expect(await stock.balanceOf(pad)).to.equal(0n);
      expect(await stock.balanceOf(posMgr)).to.equal(0n);
    });

    it("pairs the pool against the stock token, not WETH", async () => {
      const token = await createCoin();
      const pair = [await posMgr.lastToken0(), await posMgr.lastToken1()].map((a) =>
        a.toLowerCase()
      );
      expect(pair).to.include((await stock.getAddress()).toLowerCase());
      expect(pair).to.include(token.toLowerCase());
      expect(pair).to.not.include((await weth.getAddress()).toLowerCase());
    });

    it("mints token-only liquidity on the correct V3 side", async () => {
      const token = await createCoin();
      const tokenIs0 =
        token.toLowerCase() === (await posMgr.lastToken0()).toLowerCase();
      expect(await posMgr.lastAmount0()).to.equal(tokenIs0 ? MARKET : 0n);
      expect(await posMgr.lastAmount1()).to.equal(tokenIs0 ? 0n : MARKET);
      expect(await posMgr.lastTickLower()).to.equal(tokenIs0 ? 0n : -120_000n);
      expect(await posMgr.lastTickUpper()).to.equal(tokenIs0 ? 120_000n : 0n);
    });

    it("records the quote asset and locks the LP NFT", async () => {
      const token = await createCoin();
      const c = await pad.coins(token);
      expect(c.quote).to.equal(await stock.getAddress());
      expect(c.creator).to.equal(alice.address);
      expect(await posMgr.ownerOf(c.lpTokenId)).to.equal(await pad.getAddress());
      expect(await pad.lpIsLocked(token)).to.equal(true);
    });

    it("emits the pair, fee tier, and starting price for indexing", async () => {
      const tx = await pad.connect(alice).createCoin("Factory Hood", "FHOOD", stock);
      const receipt = await tx.wait();
      const ev = receipt.logs.find((l) => l.fragment?.name === "CoinCreated");
      expect(ev.args.quote).to.equal(await stock.getAddress());
      expect(ev.args.fee).to.equal(10_000n);
      expect(ev.args.initialSqrtPriceX96).to.be.greaterThan(0n);
      await expect(tx).to.emit(pad, "LiquidityLocked");
      await expect(tx).to.emit(pad, "CreatorAllocation");
    });

    it("initializes the pool at the configured starting price", async () => {
      const token = await createCoin();
      const c = await pad.coins(token);
      const pool = await ethers.getContractAt("MockV3Pool", c.pool);
      const tokenIs0 =
        token.toLowerCase() < (await stock.getAddress()).toLowerCase();
      // sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96
      const [a0, a1] = tokenIs0
        ? [T(10_000_000), TSLA_REF]
        : [TSLA_REF, T(10_000_000)];
      const expected = (bigintSqrt((a1 * (1n << 96n)) / a0)) << 48n;
      expect(await pool.sqrtPriceX96()).to.equal(expected);
    });

    it("supports quote tokens that do not use 18 decimals", async () => {
      const sixDec = await (await ethers.getContractFactory("MockStockToken")).deploy(
        "Mock Six", "mSIX", 6
      );
      // $24 worth at $324.26/share, expressed in 6 decimals.
      await pad.setQuote(sixDec, true, 74_014n);
      const token = await createCoin(sixDec);
      const c = await pad.coins(token);
      const pool = await ethers.getContractAt("MockV3Pool", c.pool);
      expect(await pool.sqrtPriceX96()).to.be.greaterThan(0n);
      expect(c.quote).to.equal(await sixDec.getAddress());
    });

    it("lets two coins launch against different stock tokens", async () => {
      const apple = await (await ethers.getContractFactory("MockStockToken")).deploy(
        "Mock Apple", "mAAPL", 18
      );
      await pad.setQuote(apple, true, TSLA_REF);
      const a = await createCoin(stock);
      const b = await createCoin(apple, bob);
      expect((await pad.coins(a)).quote).to.equal(await stock.getAddress());
      expect((await pad.coins(b)).quote).to.equal(await apple.getAddress());
      expect(await pad.coinCount()).to.equal(2n);
    });

    it("stays paused when the owner pauses it", async () => {
      await pad.pause();
      await expect(
        pad.connect(alice).createCoin("Factory Hood", "FHOOD", stock)
      ).to.be.revertedWithCustomError(pad, "EnforcedPause");
    });
  });

  describe("fees", () => {
    it("splits both sides 55/45 and pays out in the stock token", async () => {
      const token = await createCoin();
      const erc = await ethers.getContractAt("HoodToken", token);
      const [t0, t1] =
        token.toLowerCase() < (await stock.getAddress()).toLowerCase()
          ? [token, await stock.getAddress()]
          : [await stock.getAddress(), token];

      const quoteFee = T(10);
      const tokenFee = T(1000);
      await stock.mint(posMgr, quoteFee);
      // Fund the mock's token side out of the creator allocation wallet.
      await erc.connect(allocation).transfer(posMgr, tokenFee);
      const tokenIs0 = t0 === token;
      await posMgr.setCollectAmounts(
        t0, t1,
        tokenIs0 ? tokenFee : quoteFee,
        tokenIs0 ? quoteFee : tokenFee
      );

      await pad.collectPoolFees(token);
      const creatorQuote = (quoteFee * 5500n) / 10_000n;
      const creatorToken = (tokenFee * 5500n) / 10_000n;
      expect(await pad.claimableQuoteFees(token, alice.address)).to.equal(creatorQuote);
      expect(await pad.claimableQuoteFees(token, protocol.address)).to.equal(
        quoteFee - creatorQuote
      );
      expect(await pad.claimableTokenFees(token, alice.address)).to.equal(creatorToken);
      expect(await pad.claimableFees(stock, alice.address)).to.equal(creatorQuote);

      await pad.connect(alice).claimFees(token);
      expect(await stock.balanceOf(alice.address)).to.equal(creatorQuote);
      expect(await erc.balanceOf(alice.address)).to.equal(creatorToken);
      expect(await pad.claimableFees(stock, alice.address)).to.equal(0n);
    });

    it("rejects fee calls for a coin it never launched", async () => {
      await expect(pad.collectPoolFees(bob.address)).to.be.revertedWithCustomError(
        pad, "UnknownCoin"
      );
      await expect(pad.pendingCreatorFees(bob.address)).to.be.revertedWithCustomError(
        pad, "UnknownCoin"
      );
    });

    it("reverts a claim with nothing to claim", async () => {
      const token = await createCoin();
      await expect(pad.connect(alice).claimFees(token)).to.be.revertedWithCustomError(
        pad, "ZeroAmount"
      );
    });
  });
});

function bigintSqrt(value) {
  if (value < 2n) return value;
  let x = value;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + value / x) / 2n;
  }
  return x;
}
