// Deploy infra swap UMUM (bytecode resmi Uniswap) ke Robinhood TESTNET:
//   - SwapRouter02 : router swap umum (semua token yang punya pool V3)
//   - QuoterV2     : quote harga akurat (dipanggil staticCall dari frontend)
// Di MAINNET keduanya SUDAH ada resmi (SwapRouter02 0xcaf6...5cb2,
// QuoterV2 0x33e8...a9e7) — script ini hanya untuk testnet.
// Jalankan SEKALI: npx hardhat run scripts/deploy-swap-infra.js --network robinhoodTestnet

const hre = require("hardhat");

const V3_FACTORY = "0xBC7832D7B3A1D16922ddB0BeF501CCC9157CdDb7";
const POSITION_MANAGER = "0x11a81C212fb97AF8c89De811F3530Db15592faf2";
const WETH9 = "0x33e4191705c386532ba27cBF171Db86919200B94";

const routerArtifact = require("@uniswap/swap-router-contracts/artifacts/contracts/SwapRouter02.sol/SwapRouter02.json");
const quoterArtifact = require("@uniswap/v3-periphery/artifacts/contracts/lens/QuoterV2.sol/QuoterV2.json");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Gas balance (ETH):", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)));

  const Router = new hre.ethers.ContractFactory(routerArtifact.abi, routerArtifact.bytecode, deployer);
  // arg pertama = factory Uniswap V2 (tidak ada di chain ini) -> zero address.
  const router = await Router.deploy(hre.ethers.ZeroAddress, V3_FACTORY, POSITION_MANAGER, WETH9);
  await router.waitForDeployment();
  console.log("SwapRouter02:", await router.getAddress());

  const Quoter = new hre.ethers.ContractFactory(quoterArtifact.abi, quoterArtifact.bytecode, deployer);
  const quoter = await Quoter.deploy(V3_FACTORY, WETH9);
  await quoter.waitForDeployment();
  console.log("QuoterV2:", await quoter.getAddress());

  console.log("\nTempel ke hood-deployment.js + scripts/deploy.js:");
  console.log(`  swapRouter02: "${await router.getAddress()}",`);
  console.log(`  quoterV2: "${await quoter.getAddress()}",`);
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
