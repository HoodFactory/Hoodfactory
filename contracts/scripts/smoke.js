// Robinhood-testnet smoke check for a deployed instant-V3 HoodLaunchpad.
const hre = require("hardhat");

const PAD = process.env.PAD;
const TARGET = BigInt(process.env.TARGET || 3_000_000_000);

async function main() {
  if (!PAD) throw new Error("Set PAD to the deployed HoodLaunchpad address");
  const [signer] = await hre.ethers.getSigners();
  const pad = await hre.ethers.getContractAt("HoodLaunchpad", PAD);

  console.log("Creator:", signer.address);
  console.log("1) create fixed-supply coin + locked V3 market...");
  const tx = await pad.createCoin("Hood Smoke", "SMOKE");
  const receipt = await tx.wait();
  const created = receipt.logs
    .map((log) => {
      try { return pad.interface.parseLog(log); } catch { return null; }
    })
    .find((log) => log?.name === "CoinCreated");
  const token = created.args.token;
  const coin = await pad.coins(token);
  const erc = await hre.ethers.getContractAt("HoodToken", token);

  console.log("   token:", token);
  console.log("   pool:", coin.pool);
  console.log("   LP token ID:", coin.lpTokenId.toString());
  console.log(
    "   creator allocation:",
    hre.ethers.formatUnits(
      await erc.balanceOf(await pad.creatorVestingWallet()),
      18
    )
  );
  console.log("   LP locked:", await pad.lpIsLocked(token));
  console.log("   trading venue is live immediately; no curve or migration step");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
