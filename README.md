<p align="center">
  <img src="assets/fonts/banner.png" alt="HOODFACTORY Banner" width="100%">
</p>

<h1 align="center">HOODFACTORY</h1>

<p align="center">
  <strong>AI-assisted token launchpad and trading interface for Robinhood Chain</strong>
</p>

<p align="center">
  Create fixed-supply ERC-20 tokens, launch Uniswap V3 liquidity, and pair them with WETH or supported tokenized stocks.
</p>

<p align="center">
  <a href="https://www.hoodfactory.fun">
    <img src="https://img.shields.io/badge/LAUNCH_APP-D7FF2F?style=for-the-badge&labelColor=111111" alt="Launch App">
  </a>
  <a href="https://www.hoodfactory.fun/docs.html">
    <img src="https://img.shields.io/badge/DOCUMENTATION-111111?style=for-the-badge&labelColor=111111" alt="Documentation">
  </a>
  <a href="https://x.com/Aihoodfactory">
    <img src="https://img.shields.io/badge/FOLLOW_ON_X-111111?style=for-the-badge&logo=x&logoColor=white" alt="Follow on X">
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Robinhood_Chain-Mainnet-D7FF2F?style=flat-square&labelColor=111111" alt="Robinhood Chain Mainnet">
  <img src="https://img.shields.io/badge/Chain_ID-4663-D7FF2F?style=flat-square&labelColor=111111" alt="Chain ID 4663">
  <img src="https://img.shields.io/badge/Uniswap-V3-FF007A?style=flat-square&logo=uniswap&logoColor=white" alt="Uniswap V3">
  <img src="https://img.shields.io/badge/Token-ERC--20-D7FF2F?style=flat-square&labelColor=111111" alt="ERC-20">
  <img src="https://img.shields.io/badge/AI-Assisted-D7FF2F?style=flat-square&labelColor=111111" alt="AI Assisted">
</p>

---

HOODFACTORY is an AI-assisted token launchpad and trading interface built for Robinhood Chain. Users can create fixed-supply ERC-20 tokens, select either WETH or a supported tokenized stock as the pool quote asset, and interact with Uniswap V3 liquidity through their own connected wallet.

The application never takes custody of a user's wallet or private keys. Contract deployments and transactions are prepared by the interface and must be reviewed and signed by the user.

## Network and resource

- **Network:** Robinhood Chain mainnet
- **Chain ID:** `4663`
- **Application:** [hoodfactory.fun](https://www.hoodfactory.fun)
- **Documentation:** [hoodfactory.fun/docs.html](https://www.hoodfactory.fun/docs.html)
- **X / Twitter:** [@Aihoodfactory](https://x.com/Aihoodfactory)

Operational wallet addresses are intentionally omitted from this README. Contract state and transactions remain independently verifiable on-chain.

## Launch Mechanics

- Every launched token has a fixed supply of `1,000,000,000` tokens.
- `80%` of supply is deposited as single-sided Uniswap V3 liquidity.
- The LP NFT remains locked in the launchpad contract.
- `20%` is transferred to the allocation wallet configured in the launchpad.
- The current contracts do not implement an automatic cliff or linear vesting schedule.
- Standard launches use a Token/WETH pool.
- Stock-paired launches use a whitelisted tokenized stock as the quote asset.
- The WETH swap router charges a `0.5%` platform fee in addition to the Uniswap pool fee.
- Collected launchpad LP fees are accounted for on-chain and split between the token creator and protocol.

## Repository Structure

```text
├── config/                 Public Robinhood Chain stock-token catalogue
├── contracts/
│   ├── contracts/          Solidity contracts
│   ├── scripts/            Deployment and operational scripts
│   └── test/               Hardhat contract tests
├── scripts/                Public data synchronization utilities
├── src/                    Privy wallet integration source
├── supabase/               Database schemas and RLS configuration
├── index.html              Main application
├── agent-builder.html      Agent Builder interface
├── docs.html               Product documentation
└── hood-deployment.js      Public mainnet contract configuration
```

## Security Model

- Private keys and server credentials are never required by browser code.
- Server-side API implementation and production credentials are intentionally not included in this public repository.
- The production application verifies wallet-scoped actions and on-chain records server-side.
- Sensitive environment files, deployment credentials, local caches, and build artifacts are excluded from version control.

The contracts have automated test coverage, but this repository does not claim a third-party professional audit. Review the verified contracts and use the application at your own risk.

## Local Development

### Requirements

- Node.js 22 or newer
- npm

```bash
npm install
npm run build
vercel dev
```

Never place a private key or service-role credential in frontend code.

## Contract Development

```bash
cd contracts
npm install
npm test
```

Deployment requires private environment configuration that is intentionally not included in this public repository. Do not commit a populated `.env` file.

## Disclaimer

HOODFACTORY is experimental blockchain software. Tokens created through the protocol may be volatile and carry significant technical and financial risk. Nothing in this repository is financial advice.
