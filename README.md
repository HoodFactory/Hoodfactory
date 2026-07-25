# HOODFACTORY

HOODFACTORY is an AI-assisted token launchpad and trading interface built for Robinhood Chain. Users can create fixed-supply ERC-20 tokens, select either WETH or a supported tokenized stock as the pool quote asset, and interact with Uniswap V3 liquidity through their own connected wallet.

The application never takes custody of a user's wallet or private keys. Contract deployments and transactions are prepared by the interface and must be reviewed and signed by the user.

## Mainnet deployment

| Component | Address |
| --- | --- |
| HoodLaunchpad | [`0x91b641ADB805f89892526A532B6a973Bf70997cA`](https://robinhoodchain.blockscout.com/address/0x91b641ADB805f89892526A532B6a973Bf70997cA) |
| HoodStockLaunchpad | [`0x96E41c466a749275DB6FC8a052dF9e5724F8685c`](https://robinhoodchain.blockscout.com/address/0x96E41c466a749275DB6FC8a052dF9e5724F8685c) |
| HoodSwapRouter | [`0xF5032251a2385C84635aF5b2b976319720226a5d`](https://robinhoodchain.blockscout.com/address/0xF5032251a2385C84635aF5b2b976319720226a5d) |

- Network: Robinhood Chain mainnet
- Chain ID: `4663`
- Application: [hoodfactory.fun](https://www.hoodfactory.fun)
- X / Twitter: [@Aihoodfactory](https://x.com/Aihoodfactory)

Operational wallet addresses are intentionally omitted from this README. Contract state and transactions remain independently verifiable on-chain.

## Launch mechanics

- Every launched token has a fixed supply of `1,000,000,000` tokens.
- `80%` of supply is deposited as single-sided Uniswap V3 liquidity.
- The LP NFT remains locked in the launchpad contract.
- `20%` is transferred to the allocation wallet configured in the launchpad.
- The current contracts do not implement an automatic cliff or linear vesting schedule.
- Standard launches use a Token/WETH pool.
- Stock-paired launches use a whitelisted tokenized stock as the quote asset.
- The WETH swap router charges a `0.5%` platform fee in addition to the Uniswap pool fee.
- Collected launchpad LP fees are accounted for on-chain and split between the token creator and protocol.

## Repository structure

```text
config/              Public Robinhood Chain stock-token catalogue
contracts/contracts/ Solidity contracts
contracts/scripts/   Deployment and operational scripts
contracts/test/      Hardhat contract tests
scripts/             Public data synchronization utilities
src/                 Privy wallet integration source
supabase/            Database schemas and RLS configuration
index.html            Main application
agent-builder.html    Agent Builder interface
docs.html             Product documentation
hood-deployment.js    Public mainnet contract configuration
```

## Security model

- Private keys and server credentials are never required by browser code.
- Server-side API implementation and production credentials are intentionally not included in this public repository.
- The production application verifies wallet-scoped actions and on-chain records server-side.
- Sensitive environment files, deployment credentials, local caches and build artifacts are excluded from version control.

The contracts have automated test coverage, but this repository does not claim a third-party professional audit. Review the verified contracts and use the application at your own risk.

## Local development

Requirements:

- Node.js 22 or newer
- npm

```bash
npm install
npm run build
vercel dev
```

Never place a private key or service-role credential in frontend code.

## Contract development

```bash
cd contracts
npm install
npm test
```

Deployment requires private environment configuration that is intentionally not included in this public repository. Do not commit a populated `.env` file.

## Disclaimer

HOODFACTORY is experimental blockchain software. Tokens created through the protocol may be volatile and carry significant technical and financial risk. Nothing in this repository is financial advice.
