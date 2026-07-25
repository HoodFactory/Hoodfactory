const fs = require("fs");
const path = require("path");

const CHAIN_ID = 4663;
const TARGET_USD = 24n;
const ONE = 10n ** 18n;
const FILE = path.resolve(__dirname, "../config/stockTokens.json");

function decimal(value) {
  const [whole, fraction = ""] = String(value).split(".");
  return { value: BigInt(whole + fraction), scale: 10n ** BigInt(fraction.length) };
}

function referenceAmount(bid, ask, multiplier) {
  const b = decimal(bid);
  const a = decimal(ask);
  const scale = b.scale > a.scale ? b.scale : a.scale;
  const midNumerator = b.value * (scale / b.scale) + a.value * (scale / a.scale);
  const m = decimal(multiplier);
  const numerator = TARGET_USD * 2n * scale * m.scale * ONE;
  return ((numerator + (midNumerator * m.value) / 2n) / (midNumerator * m.value)).toString();
}

async function main() {
  const [assetResponse, priceResponse] = await Promise.all([
    fetch("https://api.robinhood.com/rhj/assets"),
    fetch("https://api.robinhood.com/rhj/prices"),
  ]);
  if (!assetResponse.ok || !priceResponse.ok) throw new Error("Robinhood API unavailable");
  const assets = (await assetResponse.json()).assets;
  const quotes = (await priceResponse.json()).quotes;
  const prices = new Map(quotes.map((quote) => [quote.tokenSymbol, quote]));
  const tokens = assets
    .filter((asset) => asset.status === "ASSET_STATUS_ACTIVE")
    .map((asset) => {
      const deployment = asset.deployments.find((item) => item.chainId === CHAIN_ID);
      const quote = prices.get(asset.tokenSymbol);
      if (!deployment || !quote?.bid || !quote?.ask) return null;
      const amount = referenceAmount(quote.bid, quote.ask, asset.currentMultiplier);
      return {
        symbol: asset.tokenSymbol,
        name: asset.tokenName.replace(/\s*•\s*Robinhood Token$/, ""),
        address: deployment.contractAddress,
        logoUrl: asset.logoUrl,
        decimals: 18,
        referenceAmount: amount,
        referenceNote: `10,000,000 tokens = ${amount} raw quote units; $24 target using bid/ask midpoint and multiplier ${asset.currentMultiplier}`,
      };
    })
    .filter(Boolean)
    .sort((left, right) => left.symbol.localeCompare(right.symbol));
  const config = JSON.parse(fs.readFileSync(FILE, "utf8"));
  config._readme = [
    "Whitelist of canonical Robinhood Stock Tokens accepted by HoodStockLaunchpad.",
    "Mainnet addresses, active status, prices, and corporate-action multipliers are",
    "synchronized from https://api.robinhood.com/rhj before deployment.",
    "referenceAmount prices 10,000,000 launch tokens at an approximately $24 quote",
    "value and includes currentMultiplier, as required by Robinhood's API docs.",
    "Run node scripts/sync-stock-tokens.js immediately before mainnet whitelisting.",
  ];
  config.networks[String(CHAIN_ID)].tokens = tokens;
  fs.writeFileSync(FILE, JSON.stringify(config, null, 2) + "\n");
  console.log(`Synced ${tokens.length} active Robinhood mainnet Stock Tokens.`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exitCode = 1;
});
