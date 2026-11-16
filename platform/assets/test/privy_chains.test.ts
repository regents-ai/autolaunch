// Privy's network settings come from the page's wallet chains alone: none
// without one, Base as the network wallets start on, and a lab chain on the
// lab's own public door, never a node Privy or viem ships for that id.
import {SUPPORTED_CHAINS} from "@privy-io/react-auth"
import {base, robinhood} from "viem/chains"
import {expect, it} from "vitest"

import {privyChains} from "../js/privy_chains"

it("a site with no wallet chain gives Privy no network settings", () => {
  expect(privyChains([])).toEqual({})
})

it("Base then Robinhood: Privy's own Base is the default, then viem's Robinhood Chain", () => {
  const privyBase = SUPPORTED_CHAINS.find(chain => chain.id === base.id)

  const settings = privyChains([
    {chain_id: 8453, name: "Base", rpc_url: "https://base.example.test"},
    {chain_id: 4663, name: "Robinhood Chain", rpc_url: "https://robinhood.example.test"},
  ])

  expect(privyBase).toBeDefined()
  expect(settings.defaultChain).toBe(privyBase)
  expect(settings.supportedChains).toEqual([privyBase, robinhood])
})

it("a lab chain is built from the server's name and public door, even on an id Privy lists", () => {
  const labs = [
    {chain_id: 31337, name: "Local Base fork · chain 31337", rpc_url: "https://base-lab.example.test"},
    {chain_id: 31338, name: "Robinhood test network", rpc_url: "https://robinhood-lab.example.test"},
    {chain_id: 84532, name: "Base Sepolia lab", rpc_url: "https://sepolia-lab.example.test"},
  ]
  expect(SUPPORTED_CHAINS.map(chain => chain.id)).toContain(84532)

  const settings = privyChains(labs)

  expect(settings.defaultChain).toBe(settings.supportedChains?.[0])
  expect(settings.supportedChains?.map(chain => [chain.id, chain.name, chain.rpcUrls])).toEqual(
    labs.map(lab => [lab.chain_id, lab.name, {default: {http: [lab.rpc_url]}}]),
  )
})
