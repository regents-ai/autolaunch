import {currentAddresses} from "../wallet_actions/connected_wallet"

/**
 * Tells a panel which accounts this tab's wallets are on, now and whenever that
 * changes. The panel acts for the signed-in wallet; this only lets it name the
 * browser's wallet when that is a different one. Only the latest read is sent.
 * Returns the listener's removal.
 */
export function reportBrowserWallets(push: (event: string, payload: unknown) => void): () => void {
  let latest = 0
  const report = async () => {
    const read = ++latest
    const addresses = await currentAddresses()
    if (read === latest) push("browser_wallets", {addresses})
  }
  window.addEventListener("autolaunch:wallet-state", report)
  void report()
  return () => {
    latest += 1
    window.removeEventListener("autolaunch:wallet-state", report)
  }
}
