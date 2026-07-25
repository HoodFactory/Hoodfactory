const { expect } = require("chai");
const { ethers } = require("hardhat");

const E = (n) => ethers.parseUnits(n.toString(), 18); // WETH/ETH, 18 decimals
const T = (n) => ethers.parseUnits(n.toString(), 18);
const TOTAL = T(1_000_000_000);
const CREATOR = T(200_000_000);
const MARKET = T(800_000_000);

describe("HoodLaunchpad — instant single-sided V3", () => {
  let owner, protocol, allocation, alice, bob;
  let weth, factory, posMgr, pad;

  beforeEach(async () => {
    [owner, protocol, allocation, alice, bob] = await ethers.getSigners();
    weth = await (await ethers.getContractFactory("MockWETH9")).deploy();
    factory = await (await ethers.getContractFactory("MockV3Factory")).deploy(weth);
    posMgr = await (await ethers.getContractFactory("MockPositionManager")).deploy();
    pad = await (await ethers.getContractFactory("HoodLaunchpad")).deploy(
      weth, factory, posMgr, protocol.address, allocation.address, owner.address
    );
  });

  async function createCoin(creator = alice) {
    const tx = await pad.connect(creator).createCoin("Factory Hood", "FHOOD");
    const receipt = await tx.wait();
    return receipt.logs.find((l) => l.fragment?.name === "CoinCreated").args.token;
  }

  it("creates a fixed 1B token and performs the exact 20/80 split", async () => {
    const token = await createCoin();
    const erc = await ethers.getContractAt("HoodToken", token);
    expect(await erc.totalSupply()).to.equal(TOTAL);
    expect(await erc.balanceOf(allocation.address)).to.equal(CREATOR);
    expect(await erc.balanceOf(posMgr)).to.equal(MARKET);
    expect(await erc.balanceOf(pad)).to.equal(0n);
    expect(await pad.claimableFees(protocol.address)).to.equal(0n);
  });

  it("emits allocation, liquidity lock, and creation records", async () => {
    await expect(pad.connect(alice).createCoin("Factory Hood", "FHOOD"))
      .to.emit(pad, "CreatorAllocation")
      .and.to.emit(pad, "LiquidityLocked")
      .and.to.emit(pad, "CoinCreated");
  });

  it("mints token-only liquidity on the correct V3 side", async () => {
    const token = await createCoin();
    const tokenIs0 = token.toLowerCase() === (await posMgr.lastToken0()).toLowerCase();
    expect(await posMgr.lastAmount0()).to.equal(tokenIs0 ? MARKET : 0n);
    expect(await posMgr.lastAmount1()).to.equal(tokenIs0 ? 0n : MARKET);
    expect(await posMgr.lastTickLower()).to.equal(tokenIs0 ? 0n : -120_000n);
    expect(await posMgr.lastTickUpper()).to.equal(tokenIs0 ? 120_000n : 0n);
  });

  it("keeps the LP NFT owned by the launchpad", async () => {
    const token = await createCoin();
    const c = await pad.coins(token);
    expect(await posMgr.ownerOf(c.lpTokenId)).to.equal(await pad.getAddress());
    expect(await pad.lpIsLocked(token)).to.equal(true);
  });

  it("uses the configured ordinary wallet for future creator allocations", async () => {
    await pad.connect(owner).setCreatorVestingWallet(bob.address);
    const token = await createCoin();
    expect(await (await ethers.getContractAt("HoodToken", token)).balanceOf(bob.address)).to.equal(CREATOR);
  });

  it("routes harvested WETH 55% creator and 45% protocol", async () => {
    const token = await createCoin();
    await weth.mint(posMgr, E(100));
    const wethIs0 = (await weth.getAddress()).toLowerCase() < token.toLowerCase();
    await posMgr.setCollectAmounts(
      wethIs0 ? await weth.getAddress() : token,
      wethIs0 ? token : await weth.getAddress(),
      wethIs0 ? E(100) : 0,
      wethIs0 ? 0 : E(100)
    );
    await pad.collectPoolFees(token);
    expect(await pad.claimableFees(alice.address)).to.equal(E(55));
    expect(await pad.claimableFees(protocol.address)).to.equal(E(45));
  });

  it("routes token-side LP fees 55% creator and 45% protocol", async () => {
    const token = await createCoin();
    const erc = await ethers.getContractAt("HoodToken", token);
    await erc.connect(allocation).transfer(posMgr, T(10_000));
    const wethIs0 = (await weth.getAddress()).toLowerCase() < token.toLowerCase();
    await posMgr.setCollectAmounts(
      wethIs0 ? await weth.getAddress() : token,
      wethIs0 ? token : await weth.getAddress(),
      wethIs0 ? 0 : T(10_000),
      wethIs0 ? T(10_000) : 0
    );
    await pad.collectPoolFees(token);
    expect(await pad.claimableTokenFees(token, alice.address)).to.equal(T(5_500));
    expect(await pad.claimableTokenFees(token, protocol.address)).to.equal(T(4_500));
    expect(await erc.totalSupply()).to.equal(TOTAL);
  });

  it("lets the creator collect and claim WETH and token fees in one transaction", async () => {
    const token = await createCoin();
    const erc = await ethers.getContractAt("HoodToken", token);
    await weth.mint(posMgr, E(100));
    await erc.connect(allocation).transfer(posMgr, T(10_000));
    const wethIs0 = (await weth.getAddress()).toLowerCase() < token.toLowerCase();
    await posMgr.setCollectAmounts(
      wethIs0 ? await weth.getAddress() : token,
      wethIs0 ? token : await weth.getAddress(),
      wethIs0 ? E(100) : T(10_000),
      wethIs0 ? T(10_000) : E(100)
    );
    await expect(pad.connect(alice).collectAndClaimCreatorFees(token))
      .to.emit(pad, "FeesClaimed");
    expect(await weth.balanceOf(alice.address)).to.equal(E(55));
    expect(await erc.balanceOf(alice.address)).to.equal(T(5_500));
  });

  it("pause blocks launches but not fee collection or claims", async () => {
    const token = await createCoin();
    await pad.connect(owner).pause();
    await expect(createCoin()).to.be.reverted;
    await weth.mint(posMgr, E(10));
    const wethIs0 = (await weth.getAddress()).toLowerCase() < token.toLowerCase();
    await posMgr.setCollectAmounts(
      wethIs0 ? await weth.getAddress() : token,
      wethIs0 ? token : await weth.getAddress(),
      wethIs0 ? E(10) : 0,
      wethIs0 ? 0 : E(10)
    );
    await pad.collectPoolFees(token);
    await pad.connect(alice).claimFees(token);
  });

  it("token has no owner, mint, pause, or blacklist authority", async () => {
    const token = await createCoin();
    const erc = await ethers.getContractAt("HoodToken", token);
    expect(await erc.totalSupply()).to.equal(TOTAL);
    expect(erc.interface.getFunction("mint")).to.equal(null);
    expect(erc.interface.getFunction("owner")).to.equal(null);
    expect(erc.interface.getFunction("pause")).to.equal(null);
  });
});

describe("HoodSwapRouter — Uniswap V3 pool with native ETH in/out", () => {
  let owner, protocol, allocation, alice;
  let weth, factory, posMgr, pad, router, token, erc, pool;

  const deadline = async () =>
    (await ethers.provider.getBlock("latest")).timestamp + 600;

  beforeEach(async () => {
    [owner, protocol, allocation, alice] = await ethers.getSigners();
    weth = await (await ethers.getContractFactory("MockWETH9")).deploy();
    factory = await (await ethers.getContractFactory("MockV3Factory")).deploy(weth);
    posMgr = await (await ethers.getContractFactory("MockPositionManager")).deploy();
    pad = await (await ethers.getContractFactory("HoodLaunchpad")).deploy(
      weth, factory, posMgr, protocol.address, allocation.address, owner.address
    );
    router = await (await ethers.getContractFactory("HoodSwapRouter")).deploy(
      weth, pad, factory, protocol.address
    );
    const receipt = await (await pad.connect(alice).createCoin("Factory Hood", "FHOOD")).wait();
    token = receipt.logs.find((l) => l.fragment?.name === "CoinCreated").args.token;
    erc = await ethers.getContractAt("HoodToken", token);
    pool = (await pad.coins(token)).pool;
    await erc.connect(allocation).transfer(pool, T(100_000_000));
    // Back the mock WETH with real ETH so router withdraw() can pay sells.
    await weth.connect(owner).deposit({ value: E(100) });
  });

  it("charges 0.5% WETH platform fee on ETH buys", async () => {
    const before = await weth.balanceOf(protocol.address);
    await router.connect(alice).swapExactInput(
      token, true, E(0.01), 0, alice.address, await deadline(), { value: E(0.01) }
    );
    expect(await weth.balanceOf(protocol.address)).to.equal(before + E(0.00005));
    expect(await erc.balanceOf(alice.address)).to.be.gt(0n);
  });

  it("rejects a buy whose msg.value does not match amountIn", async () => {
    await expect(
      router.connect(alice).swapExactInput(
        token, true, E(0.01), 0, alice.address, await deadline(), { value: E(0.5) }
      )
    ).to.be.revertedWithCustomError(router, "WrongEthAmount");
  });

  it("quotes the exact V3 buy path before executing it", async () => {
    const amountIn = E(0.01);
    const [quoted] = await router.quoteExactInput.staticCall(token, true, amountIn);
    const before = await erc.balanceOf(alice.address);
    await router.connect(alice).swapExactInput(
      token, true, amountIn, quoted, alice.address, await deadline(), { value: amountIn }
    );
    expect(await erc.balanceOf(alice.address) - before).to.equal(quoted);
  });

  it("charges 0.5% of the ETH output on sells and pays the seller in ETH", async () => {
    await router.connect(alice).swapExactInput(
      token, true, E(0.01), 0, alice.address, await deadline(), { value: E(0.01) }
    );
    await weth.mint(pool, E(50));
    const sellAmount = (await erc.balanceOf(alice.address)) / 2n;
    await erc.connect(alice).approve(router, sellAmount);
    const protocolBefore = await weth.balanceOf(protocol.address);
    const aliceBefore = await ethers.provider.getBalance(alice.address);
    const tx = await router.connect(alice).swapExactInput(
      token, false, sellAmount, 0, alice.address, await deadline()
    );
    const rc = await tx.wait();
    const gasCost = rc.gasUsed * rc.gasPrice;
    expect(await weth.balanceOf(protocol.address)).to.be.gt(protocolBefore);
    expect(await ethers.provider.getBalance(alice.address)).to.be.gt(
      aliceBefore - gasCost
    );
  });

  it("quotes the exact V3 sell path including the platform output fee", async () => {
    await router.connect(alice).swapExactInput(
      token, true, E(0.01), 0, alice.address, await deadline(), { value: E(0.01) }
    );
    await weth.mint(pool, E(50));
    const sellAmount = (await erc.balanceOf(alice.address)) / 3n;
    await erc.connect(alice).approve(router, sellAmount);
    const [quoted] = await router.quoteExactInput.staticCall(token, false, sellAmount);
    const before = await ethers.provider.getBalance(alice.address);
    const tx = await router.connect(alice).swapExactInput(
      token, false, sellAmount, quoted, alice.address, await deadline()
    );
    const rc = await tx.wait();
    const gasCost = rc.gasUsed * rc.gasPrice;
    expect(await ethers.provider.getBalance(alice.address) - before + gasCost).to.equal(quoted);
  });
});
