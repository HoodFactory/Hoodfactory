import React, {useEffect, useRef} from "react";
import {createRoot} from "react-dom/client";
import {PrivyProvider, usePrivy, useWallets} from "@privy-io/react-auth";
import {defineChain} from "viem";

const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
  rpcUrls: {default: {http: ["https://rpc.mainnet.chain.robinhood.com"]}},
  blockExplorers: {default: {name: "Blockscout", url: "https://robinhoodchain.blockscout.com"}},
});

const pendingConnects = [];
let currentWallet = null;
let bridgeReady = false;
let bridgeLogin = null;
let bridgeLogout = null;

function emitWallet(address) {
  window.dispatchEvent(new CustomEvent("hood:privy-wallet", {detail: {address}}));
}

window.hoodPrivy = {
  async connect() {
    if (!bridgeReady) await new Promise((resolve) => window.addEventListener("hood:privy-ready", resolve, {once: true}));
    if (currentWallet) return currentWallet.address;
    return new Promise((resolve, reject) => {
      pendingConnects.push({resolve, reject});
      try { bridgeLogin(); } catch (error) { pendingConnects.pop(); reject(error); }
    });
  },
  async disconnect() {
    if (bridgeLogout) await bridgeLogout();
    currentWallet = null;
    emitWallet(null);
  },
  async getProvider() {
    if (!currentWallet) throw new Error("Connect your wallet first.");
    return currentWallet.getEthereumProvider();
  },
  getAddress() { return currentWallet?.address || null; },
  isReady() { return bridgeReady; },
};

function Bridge() {
  const {ready, authenticated, login, logout} = usePrivy();
  const {ready: walletsReady, wallets} = useWallets();
  const previous = useRef(null);
  currentWallet = wallets[0] || null;

  useEffect(() => {
    if (!ready || !walletsReady) return;
    const address = authenticated && currentWallet ? currentWallet.address : null;
    if (previous.current !== address) {
      previous.current = address;
      emitWallet(address);
    }
    if (address) {
      while (pendingConnects.length) pendingConnects.shift().resolve(address);
    }
  }, [ready, walletsReady, authenticated, wallets]);

  useEffect(() => {
    bridgeLogin = login;
    bridgeLogout = logout;
    if (ready && walletsReady && !bridgeReady) {
      bridgeReady = true;
      window.dispatchEvent(new Event("hood:privy-ready"));
    }
  }, [ready, walletsReady, authenticated, login, logout, wallets]);

  return null;
}

const mount = document.createElement("div");
mount.id = "hood-privy-root";
document.body.appendChild(mount);

createRoot(mount).render(
  <PrivyProvider
    appId="cmrzdm55y00210cjpb85dy3hy"
    clientId="client-WY6bNpHQSPs85MFeXwgpHQeXwVHzkx7QkFeCri55EmdoE"
    config={{
      loginMethods: ["wallet", "email"],
      defaultChain: robinhood,
      supportedChains: [robinhood],
      appearance: {theme: "dark", accentColor: "#6c63ff", showWalletLoginFirst: true},
      embeddedWallets: {ethereum: {createOnLogin: "users-without-wallets"}},
    }}
  >
    <Bridge />
  </PrivyProvider>
);
