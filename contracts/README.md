# HOODFACTORY Contracts

Solidity contracts for the HOODFACTORY launchpad on Robinhood Chain.

## Components

- `HoodToken.sol` — fixed-supply ERC-20 deployed by the launchpads.
- `HoodLaunchpad.sol` — creates Token/WETH Uniswap V3 pools and locks the LP NFT.
- `HoodStockLaunchpad.sol` — creates pools quoted in whitelisted tokenized stocks.
- `HoodSwapRouter.sol` — native ETH entrypoint for Token/WETH launchpad markets.
- `interfaces/` — minimal external protocol interfaces.
- `mocks/` — test-only contracts.

Each launch creates a fixed supply of one billion tokens. Eighty percent is used for single-sided liquidity and twenty percent is transferred to the allocation wallet configured in the launchpad. The current contracts do not enforce an automatic cliff or linear vesting schedule.

## Development

```bash
npm install
npm run build
npm test
```

The test suite covers supply allocation, pool creation, liquidity locking, quote-token whitelisting, swap fees, fee accounting, access control and pause behavior.

## Environment

Private deployment configuration is intentionally not included in this public repository. Never commit deployment keys, populated environment files, treasury credentials, or server API keys.

## Commands

```bash
npm run deploy:testnet
npm run deploy:mainnet
npm run deploy:stock:testnet
npm run deploy:stock:mainnet
npm run smoke:testnet
```

Mainnet deployment scripts fail closed unless the required treasury and allocation configuration is explicitly supplied.

## Security notice

Deployment keys, treasury credentials and API keys must remain outside the repository. Public contract addresses, ABIs, RPC endpoints and verified source code are not secrets.

These contracts have automated tests but do not claim a third-party professional audit.
