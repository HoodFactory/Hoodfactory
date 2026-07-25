const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

// Deploy HoodStockLaunchpad — launchpad kedua yang pasangan pool-nya Stock
// Token, berdampingan dengan HoodLaunchpad yang sudah jalan. Script ini TIDAK
// menyentuh launchpad/router lama maupun coin yang sudah ter-launch.
//
// Testnet: Stock Token asli tidak ada di sana, jadi script men-deploy
// MockStockToken (faucet terbuka) lalu menulis alamatnya balik ke
// config/stockTokens.json.
// Mainnet: alamat sudah terisi dari Blockscout, tidak ada yang di-deploy.

const NETWORKS = {
  robinhoodTestnet: {
    chainId: 46630,
    explorerUrl: "https://explorer.testnet.chain.robinhood.com",
    v3Factory: "0xBC7832D7B3A1D16922ddB0BeF501CCC9157CdDb7",
    positionManager: "0x11a81C212fb97AF8c89De811F3530Db15592faf2",
  },
  robinhoodMainnet: {
    chainId: 4663,
    explorerUrl: "https://robinhoodchain.blockscout.com",
    v3Factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa", // Uniswap resmi
    positionManager: "0x73991a25c818bf1f1128deaab1492d45638de0d3", // Uniswap resmi
  },
};

const CONFIG_FILE = path.resolve(__dirname, "../../config/stockTokens.json");
const DEPLOYMENT_FILE = path.resolve(__dirname, "../../hood-deployment.js");

async function main() {
  const netName = hre.network.name;
  const net = NETWORKS[netName];
  if (!net) {
    throw new Error(`Network ${netName} tidak dikenal di deploy-stock-launchpad.js`);
  }

  const catalog = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  const entry = catalog.networks[String(net.chainId)];
  if (!entry || !entry.tokens || entry.tokens.length === 0) {
    throw new Error(`config/stockTokens.json belum punya token untuk chain ${net.chainId}`);
  }

  const [deployer] = await hre.ethers.getSigners();
  const expectedDeployer = process.env.EXPECTED_DEPLOYER;
  if (
    expectedDeployer &&
    deployer.address.toLowerCase() !== expectedDeployer.toLowerCase()
  ) {
    throw new Error(`Deployer mismatch: expected ${expectedDeployer}, got ${deployer.address}`);
  }
  const treasury = process.env.PROTOCOL_TREASURY || deployer.address;
  const creatorVestingWallet =
    process.env.CREATOR_VESTING_WALLET || deployer.address;
  if (netName === "robinhoodMainnet" && (!process.env.PROTOCOL_TREASURY || !process.env.CREATOR_VESTING_WALLET)) {
    throw new Error("Mainnet requires explicit PROTOCOL_TREASURY and CREATOR_VESTING_WALLET");
  }
  console.log("Network:", netName, `(chainId ${net.chainId})`);
  console.log("Deployer:", deployer.address);
  console.log(
    "Gas balance (ETH):",
    hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address))
  );

  // Daftar penuh ada 50 saham. Set STOCK_MAX untuk membatasi berapa yang
  // di-deploy/di-whitelist dalam satu jalan (berguna di testnet: 50 mock =
  // 50 tx deploy + 50 tx whitelist). Jalankan lagi nanti untuk sisanya.
  // targets berisi objek yang SAMA dengan yang ada di catalog, jadi mengisi
  // t.address di bawah tetap ikut tersimpan saat catalog ditulis ulang.
  const max = Number(process.env.STOCK_MAX || 0);
  const targets = max > 0 ? entry.tokens.slice(0, max) : entry.tokens;

  // 1. Testnet: deploy mock Stock Token untuk entri yang alamatnya masih kosong.
  if (entry.mock) {
    for (const t of targets) {
      if (/^0x[0-9a-fA-F]{40}$/.test(t.address || "")) {
        console.log(`${t.symbol}: sudah ada di ${t.address}, dilewati`);
        continue;
      }
      const mock = await hre.ethers.deployContract("MockStockToken", [
        t.name,
        t.symbol,
        t.decimals,
      ]);
      await mock.waitForDeployment();
      t.address = await mock.getAddress();
      console.log(`${t.symbol}: ${t.address}`);
    }
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(catalog, null, 2) + "\n");
    console.log("config/stockTokens.json diperbarui.");
  }

  const ready = targets.filter((t) =>
    /^0x[0-9a-fA-F]{40}$/.test(t.address || "")
  );
  if (ready.length === 0) {
    throw new Error(
      "Tidak ada Stock Token dengan alamat valid. Isi config/stockTokens.json dari Blockscout dulu."
    );
  }

  // 2. Launchpad stock-pair.
  const args = [
    net.v3Factory,
    net.positionManager,
    treasury,
    creatorVestingWallet,
    deployer.address,
  ];
  const pad = await hre.ethers.deployContract("HoodStockLaunchpad", args);
  await pad.waitForDeployment();
  const addr = await pad.getAddress();
  console.log("HoodStockLaunchpad:", addr);
  console.log("Explorer:", `${net.explorerUrl}/address/${addr}`);

  // 3. Whitelist on-chain — gerbang terakhir, tidak bisa dilewati frontend.
  for (const t of ready) {
    const tx = await pad.setQuote(t.address, true, t.referenceAmount);
    await tx.wait();
    console.log(`whitelist ${t.symbol} (${t.address}) ref=${t.referenceAmount}`);
  }

  // 4. Sisipkan alamat ke hood-deployment.js tanpa menulis ulang file-nya,
  //    supaya konfigurasi launchpad/router lama tetap utuh apa adanya.
  let deployment = fs.readFileSync(DEPLOYMENT_FILE, "utf8");
  if (/stockLaunchpad:/.test(deployment)) {
    deployment = deployment.replace(
      /( *)stockLaunchpad: "[^"]*",\n/,
      `$1stockLaunchpad: "${addr}",\n`
    );
  } else {
    deployment = deployment.replace(
      /( *)(launchpad: "[^"]*",\n)/,
      `$1$2$1stockLaunchpad: "${addr}",\n`
    );
  }
  fs.writeFileSync(DEPLOYMENT_FILE, deployment);
  console.log("hood-deployment.js diperbarui:", DEPLOYMENT_FILE);

  console.log("Verifying on Blockscout...");
  try {
    await hre.run("verify:verify", { address: addr, constructorArguments: args });
    console.log("HoodStockLaunchpad verified.");
  } catch (err) {
    console.error("Verifikasi gagal, ulangi manual dengan:");
    console.error(
      `npx hardhat verify --network ${netName} ${addr} ${args.join(" ")}`
    );
    console.error(String(err.message || err));
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
