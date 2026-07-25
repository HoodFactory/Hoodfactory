// Deploy Uniswap V3 core infra (canonical bytecode dari npm @uniswap) ke
// Robinhood TESTNET. Perlu karena Uniswap resmi baru ada di MAINNET Robinhood
// (factory 0x1f7d...2efa dst) — di testnet 46630 belum ada deployment resmi.
//
// Yang dideploy: UniswapV3Factory + NonfungiblePositionManager (descriptor 0x0,
// tokenURI tidak dipakai launchpad). WETH9 TIDAK dideploy — testnet sudah punya
// WETH9 canonical di 0x33e4191705c386532ba27cBF171Db86919200B94 (170rb holder).
//
// Jalankan SEKALI saja: npm run deploy:infra:testnet
// Hasilnya tempel ke scripts/deploy.js bagian ROBINHOOD_TESTNET.

const hre = require("hardhat");

const WETH9_TESTNET = "0x33e4191705c386532ba27cBF171Db86919200B94";

const factoryArtifact = require("@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json");
const positionManagerArtifact = require("@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Gas balance (ETH):", hre.ethers.formatEther(balance));
  if (balance === 0n) {
    throw new Error(
      "Saldo 0 — ambil testnet ETH dulu di https://faucet.testnet.chain.robinhood.com"
    );
  }

  const Factory = new hre.ethers.ContractFactory(
    factoryArtifact.abi,
    factoryArtifact.bytecode,
    deployer
  );
  const factory = await Factory.deploy();
  await factory.waitForDeployment();
  const factoryAddr = await factory.getAddress();
  console.log("UniswapV3Factory:", factoryAddr);

  // Fee tier 1% (10000, spacing 200) sudah aktif dari constructor v3-core 1.0.x.
  const spacing = await factory.feeAmountTickSpacing(10000);
  console.log("feeAmountTickSpacing(10000):", spacing.toString());

  const PositionManager = new hre.ethers.ContractFactory(
    positionManagerArtifact.abi,
    positionManagerArtifact.bytecode,
    deployer
  );
  const npm_ = await PositionManager.deploy(
    factoryAddr,
    WETH9_TESTNET,
    hre.ethers.ZeroAddress // token descriptor: tidak dipakai (tokenURI saja)
  );
  await npm_.waitForDeployment();
  const npmAddr = await npm_.getAddress();
  console.log("NonfungiblePositionManager:", npmAddr);

  console.log("\nTempel ke scripts/deploy.js:");
  console.log(`  weth: "${WETH9_TESTNET}",`);
  console.log(`  v3Factory: "${factoryAddr}",`);
  console.log(`  positionManager: "${npmAddr}",`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
