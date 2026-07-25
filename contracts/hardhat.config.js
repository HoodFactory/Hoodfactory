require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const ROBINHOOD_TESTNET_RPC =
  process.env.ROBINHOOD_TESTNET_RPC || "https://rpc.testnet.chain.robinhood.com";
const ROBINHOOD_MAINNET_RPC =
  process.env.ROBINHOOD_MAINNET_RPC || "https://rpc.mainnet.chain.robinhood.com";
const PRIVATE_KEY = process.env.PRIVATE_KEY;

module.exports = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
      // Robinhood Chain is a young Arbitrum Orbit chain; paris avoids any
      // dependence on newer opcodes.
      evmVersion: "paris",
    },
  },
  networks: {
    robinhoodTestnet: {
      url: ROBINHOOD_TESTNET_RPC,
      chainId: 46630,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    robinhoodMainnet: {
      url: ROBINHOOD_MAINNET_RPC,
      chainId: 4663,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: { robinhoodTestnet: "blockscout", robinhoodMainnet: "blockscout" },
    customChains: [
      {
        network: "robinhoodTestnet",
        chainId: 46630,
        urls: {
          apiURL: "https://explorer.testnet.chain.robinhood.com/api",
          browserURL: "https://explorer.testnet.chain.robinhood.com",
        },
      },
      {
        network: "robinhoodMainnet",
        chainId: 4663,
        urls: {
          apiURL: "https://robinhoodchain.blockscout.com/api",
          browserURL: "https://robinhoodchain.blockscout.com",
        },
      },
    ],
  },
};
