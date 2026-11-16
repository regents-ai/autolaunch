import {SUPPORTED_CHAINS, type PrivyClientConfig} from "@privy-io/react-auth"
import {base, robinhood, type Chain} from "viem/chains"

import {viemChain, type StepChain} from "./wallet_actions/send_step"

// Privy's own Base, carrying Privy's node for the Privy wallet. Privy 3.51.1
// lists Base, and the unit test holds it to that.
const privyBase = SUPPORTED_CHAINS.find(chain => chain.id === base.id)!

/**
 * Privy's network settings for the networks the site's wallet buttons send on:
 * the page's `wallet-chains` (`Autolaunch.Chain.Client.chains/0`), Base first.
 * Base is Privy's own; Robinhood Chain, which Privy's list lacks, is viem's,
 * whose explorer a wallet app asked to add the network wants; any other network
 * (a lab chain) is built from the name and public door the server gives its
 * steps. A site with no wallet chain has no wallet buttons, so Privy is given
 * no network settings.
 */
export function privyChains(chains: StepChain[]): Pick<PrivyClientConfig, "defaultChain" | "supportedChains"> {
  const networks = chains.map(network)
  const [defaultChain] = networks
  return defaultChain ? {defaultChain, supportedChains: networks} : {}
}

function network(chain: StepChain): Chain {
  if (chain.chain_id === base.id) return privyBase
  if (chain.chain_id === robinhood.id) return robinhood
  return viemChain(chain)
}
