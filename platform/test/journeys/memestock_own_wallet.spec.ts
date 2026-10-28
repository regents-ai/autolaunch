import {createWalletClient, defineChain, encodeFunctionData, http, parseAbi, type Hex} from "viem"
import {privateKeyToAccount} from "viem/accounts"
import {Agent} from "./support/agent"
import {balanceOf, call, launchCreated, memestock, mineTo, mintStock, receipt, rpc, sendAs} from "./support/chain"
import {AAPLC, draftFor} from "./support/launch"
import {pairWith, unpair} from "./support/pairing"
import {onSite} from "./support/site"
import {expect, holdWallet, people, ready, signIn, test, type Sent} from "./support/person"

// L9: a paired agent launches a Memestock straight through the launchpad, from
// its own wallet, with no review on this site. The launchpad records that
// wallet as the launch's creator: its 0.5% creator allocation and its 0.3%
// share of every trade's fee go to that wallet only. The site lists the launch
// on its own discovery cycle under that wallet, with no account, and keeps
// only what passes its checks. Feature map: operations/FEATURES.md, Agents.
test.use({wallet: people.a.wallet})

const fork = defineChain({
  id: 31_337,
  name: "Base copy",
  nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18},
  rpcUrls: {default: {http: [process.env.ANVIL_RPC!]}},
})

const hookAbi = parseAbi([
  "function settleCreatorLane(bytes32 poolId) returns (uint256)",
  "function accrued(bytes32 poolId) view returns (uint256 creatorLane, uint256 regentLane, uint256 stakerLane)",
])

async function read(to: string, abi: any, functionName: string, args: unknown[] = []): Promise<bigint> {
  return BigInt(await call(to, encodeFunctionData({abi, functionName, args} as any) as Hex))
}

const nextStep = (page: import("@playwright/test").Page) =>
  page.locator("[data-onchain-step]:visible:not([disabled])").first()

async function listed(symbol: string): Promise<any> {
  const answer = await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/auctions?q=${symbol}`)).json()
  return answer.data.find((auction: any) => auction.token_symbol === symbol)
}

test("L9: an agent launches from its own wallet, owns the launch, is paid its creator share, and the site lists it under that wallet", async ({page, browser}, info) => {
  test.skip(info.project.name !== "desktop", "one run: it waits on the site's own discovery cycle and the auction's whole life")
  test.setTimeout(20 * 60_000)

  await signIn(page, people.a)
  const agent = new Agent("own-wallet")
  await pairWith(page, agent, "Own wallet")

  // The agent stores its picture as any draft's picture is stored, so the launch
  // carries a picture this site keeps; its text is its own.
  const tag = agent.address.slice(2, 6).toUpperCase()
  const draft = draftFor(`W${tag}`)
  const saved = agent.autolaunch(["drafts", "memestock", "save"], draft)
  expect(saved.status, saved.stdout).toBe(0)
  const picture = saved.json.data.image as string

  // The agent sends launch() itself, signed with its own key.
  await rpc("anvil_setBalance", [agent.address, "0x56bc75e2d63100000"])
  const wallet = createWalletClient({account: privateKeyToAccount(agent.privateKey), chain: fork, transport: http()})
  const {addresses, abis} = memestock()
  const hash = await wallet.sendTransaction({
    to: addresses.launchpad as Hex,
    data: encodeFunctionData({
      abi: abis.launchpad,
      functionName: "launch",
      args: [{
        name: draft.name,
        symbol: draft.symbol,
        description: draft.description,
        website: "javascript:alert(1)",
        image: picture,
        stock: AAPLC,
      }],
    } as any),
  })
  const mined = await receipt(hash)
  expect(mined.status).toBe("0x1")
  const created = launchCreated(mined)
  const launchId = BigInt(created.launchId)
  expect(String(created.launcher).toLowerCase()).toBe(agent.address)
  const auction = String(created.auction).toLowerCase()
  const token = String(created.newToken).toLowerCase()

  // The site finds it on its own cycle (every five minutes) and lists it under the agent's wallet.
  await expect.poll(() => listed(draft.symbol), {timeout: 8 * 60_000, intervals: [10_000]}).toBeTruthy()
  const listing = await listed(draft.symbol)
  expect(listing.address.toLowerCase()).toBe(auction)
  const row = JSON.parse(onSite("auction_row.exs", {JOURNEY_AUCTION: auction, JOURNEY_PERSON: "did:privy:journey-a"})
    .split("JOURNEY_RESULT ")[1].split("\n")[0])
  expect(row).toMatchObject({origin: "chain", creator_account: null, creator_wallet: agent.address, image: picture, website: null})

  // Its page names the agent's wallet as creator, and shows the picture the site keeps.
  await page.goto(new URL(listing.url).pathname)
  await ready(page)
  await expect(page.locator(".creator-label a")).toHaveAttribute("title", agent.address)
  await expect(page.locator("main")).toContainText(draft.symbol)
  await expect(page.locator("main")).not.toContainText("javascript:")

  // Person B bids past the minimum, the auction ends and graduates, all from its page.
  await mineTo(Number(await read(auction, abis.auction, "startBlock")))
  const bidder = await browser.newContext({...info.project.use, baseURL: process.env.AUTOLAUNCH_URL})
  const bids: Sent[] = []
  const outside = await holdWallet(bidder, process.env.AUTOLAUNCH_URL!, people.b.wallet, bids)
  const b = await bidder.newPage()
  await mintStock(AAPLC, people.b.wallet, 10n ** 9n)
  await signIn(b, people.b)
  await expect.poll(async () => (await listed(draft.symbol)).state, {timeout: 120_000}).toBe("active")
  await b.goto(new URL(listing.url).pathname)
  await ready(b)
  await b.locator(".bid-switch label", {hasText: "AAPLc"}).click()
  await b.getByRole("textbox", {name: "Max budget"}).fill("0.5")
  const placed = b.locator(".bid-placed")
  for (let press = 0; press < 4 && !(await placed.isVisible()); press++) {
    const before = bids.length
    await nextStep(b).click()
    await expect.poll(() => bids.length, {timeout: 30_000}).toBeGreaterThan(before)
    await b.waitForTimeout(1_000)
  }
  await expect(placed).toBeVisible({timeout: 60_000})

  await mineTo(Number(await read(auction, abis.auction, "endBlock")))
  await mineTo(Number(await read(auction, abis.auction, "claimBlock")) + 200)
  await expect.poll(async () => (await listed(draft.symbol)).state, {timeout: 120_000}).toBe("ended")
  await b.goto(new URL(listing.url).pathname)
  await ready(b)
  await b.getByRole("button", {name: /^Finish/}).click()
  await expect.poll(async () => (await listed(draft.symbol)).state, {timeout: 120_000}).toBe("graduated")

  // The creator allocation vests to the agent's wallet and to no one else: anyone may release it.
  await mineTo(Number(mined.blockNumber) + 100_000)
  expect(await balanceOf(token, agent.address)).toBe(0n)
  await sendAs(people.b.wallet, addresses.launchpad, encodeFunctionData({
    abi: abis.launchpad, functionName: "releaseCreatorVesting", args: [launchId],
  } as any) as Hex)
  expect(await balanceOf(token, agent.address)).toBeGreaterThan(0n)

  // Person B buys the token on its page; the creator's share of that trade's fee
  // goes to the agent's wallet once anyone settles it.
  const tokenPage = (await (await fetch(`${process.env.AUTOLAUNCH_URL}/api/v1/tokens?q=${draft.symbol}`)).json())
    .data.find((listedToken: any) => listedToken.symbol === draft.symbol)
  expect(tokenPage, "the token is listed").toBeTruthy()
  await b.goto(new URL(tokenPage.url).pathname)
  await ready(b)
  await expect(b.locator(".creator-label a")).toHaveAttribute("title", agent.address)
  await b.getByRole("textbox", {name: /Amount of AAPLc to sell/}).fill("0.1")
  await b.getByRole("button", {name: "Review"}).click()
  const swaps = bids.length
  for (let press = 0; press < 3 && (await balanceOf(token, people.b.wallet)) === 0n; press++) {
    await nextStep(b).click()
    await expect.poll(() => bids.length, {timeout: 30_000}).toBeGreaterThan(swaps + press)
  }
  expect(await balanceOf(token, people.b.wallet)).toBeGreaterThan(0n)

  const poolId = (await rpc("eth_call", [{
    to: addresses.launchpad,
    data: encodeFunctionData({abi: abis.launchpad, functionName: "launches", args: [launchId]} as any),
  }, "latest"])).slice(2 + 64 * 10, 2 + 64 * 11)
  // The first of the three lanes `accrued` answers is the creator's.
  const accrued = await call(addresses.hook, encodeFunctionData({abi: hookAbi, functionName: "accrued", args: [`0x${poolId}`]}))
  const lane = BigInt(accrued.slice(0, 66))
  expect(lane).toBeGreaterThan(0n)
  const stockBefore = await balanceOf(AAPLC, agent.address)
  await sendAs(people.b.wallet, addresses.hook, encodeFunctionData({
    abi: hookAbi, functionName: "settleCreatorLane", args: [`0x${poolId}`],
  }) as Hex)
  expect(await balanceOf(AAPLC, agent.address) - stockBefore).toBe(lane)

  await bidder.close()
  expect(outside, "requests that left the machine").toEqual([])
  unpair("did:privy:journey-a", agent.address)
})
