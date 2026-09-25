import {connectedAddresses} from "../wallet_actions/connected_wallet"

/**
 * Tells a panel which wallets this tab has connected, now and whenever that
 * changes. The panel acts for the signed-in wallet; this only lets it name the
 * browser's wallet when that is a different one. Returns the listener's removal.
 */
export function reportBrowserWallets(push: (event: string, payload: unknown) => void): () => void {
  const report = () => push("browser_wallets", {addresses: connectedAddresses()})
  window.addEventListener("autolaunch:wallet-state", report)
  report()
  return () => window.removeEventListener("autolaunch:wallet-state", report)
}
