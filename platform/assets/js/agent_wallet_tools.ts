// The page tools that press a wallet card for an agent (WebMCP,
// document.modelContext). A card names the tools it answers in
// `data-agent-tools`, and a settlement card names its bid in `data-agent-bid`;
// a tool is registered while a card on the page answers it. A call goes to the
// card's server side as an `agent_press`, which prepares exactly what the card's
// own button would send and hands it back to be sent at once, so the call opens
// the person's wallet the same way a press does. Every call reaches the wallet,
// including one made while an earlier one is still with it.
import manifest from "../../priv/tool_manifest.json" with {type: "json"}

export type AgentOutcome =
  | {outcome: "sent"; transaction_hash: string; message: string}
  | {outcome: "not_sent"; message: string}
  | {outcome: "unknown"; message: string}

/** What the server attaches to a review sent for an agent's call. */
export type AgentCall = {call: string; remaining: string[]}

type Property = {type: "string"; enum?: string[]; pattern?: string; maxLength?: number}
type Entry = {
  name: string
  title: string
  description: string
  input_schema: {type: "object"; properties: Record<string, Property>; required: string[]; additionalProperties: false}
  annotations: {readOnlyHint: boolean; untrustedContentHint: boolean; consequentialHint: boolean}
  scope: string
}
type Input = Record<string, string>
type Card = {bid?: string; call(tool: string, input: Input, signal?: AbortSignal): Promise<AgentOutcome>}
type ModelContext = {
  registerTool(
    tool: Omit<Entry, "input_schema" | "scope"> & {
      inputSchema: Entry["input_schema"]
      execute(input: unknown, client?: {signal?: AbortSignal}): Promise<AgentOutcome>
    },
    options: {signal: AbortSignal},
  ): Promise<void>
}
type CardHook = {
  el: HTMLElement
  handleEvent(event: string, callback: (payload: unknown) => void): void
  pushEventTo(target: HTMLElement, event: string, payload: unknown): Promise<PromiseSettledResult<unknown>[]>
}

const entries = new Map(
  (manifest.tools as unknown as Entry[]).filter(entry => entry.scope !== "site").map(entry => [entry.name, entry]),
)
const registered = new Map<string, {lifetime: AbortController; cards: Set<Card>}>()

const notSent = (message: string): AgentOutcome => ({outcome: "not_sent", message})

// Why nothing was sent, or may have been, in words for the agent to act on.
const failures: Record<string, AgentOutcome> = {
  wallet_unavailable: notSent(
    "Nothing was sent. The wallet the person signed in with is not connected in this tab, so the page asked them to connect it. Call again once it is connected.",
  ),
  network_mismatch: notSent(
    "Nothing was sent. The person's wallet is on a different network. Ask them to switch it, then call again.",
  ),
  switch_declined: notSent(
    "Nothing was sent. The person declined switching their wallet to this network. Ask them to accept the switch, then call again.",
  ),
  wrong_account: notSent(
    "Nothing was sent. The wallet in this tab is on a different account from the one the person signed in with. Ask them to switch it to the signed-in account, then call again.",
  ),
  wallet_declined: notSent("The person declined in their wallet. Nothing was sent."),
  send_unconfirmed: {
    outcome: "unknown",
    message: "The wallet may have sent this. Ask the person to check their wallet activity before calling again.",
  },
}

export function failed(reason: string): AgentOutcome {
  return failures[reason] ?? notSent("Nothing was sent. The wallet did not open; ask the person to check it is unlocked, then call again.")
}

export function sent(transaction_hash: string, remaining: string[]): AgentOutcome {
  const message = remaining.length
    ? `Sent. Still to send: ${remaining.join(", then ")}. Wait a few seconds for this step to land, then call this tool again with the same values to send the next one; a call before it lands asks the wallet for this step again.`
    : "Sent. The page shows when it lands, and autolaunch_my_positions reads the result."
  return {outcome: "sent", transaction_hash, message}
}

function valid(entry: Entry, input: unknown): input is Input {
  if (!input || typeof input !== "object" || Array.isArray(input)) return false
  const values = input as Record<string, unknown>
  const {properties, required} = entry.input_schema
  if (required.some(key => !Object.hasOwn(values, key))) return false
  return Object.entries(values).every(([key, value]) => {
    const property = properties[key]
    if (!property || typeof value !== "string") return false
    if (property.maxLength !== undefined && value.length > property.maxLength) return false
    if (property.enum && !property.enum.includes(value)) return false
    return !property.pattern || new RegExp(property.pattern).test(value)
  })
}

async function execute(entry: Entry, input: unknown, signal?: AbortSignal): Promise<AgentOutcome> {
  if (!valid(entry, input)) {
    const fields = Object.keys(entry.input_schema.properties).join(", ") || "no fields"
    return notSent(`Nothing was sent. Use only the documented fields (${fields}), as strings; amounts are plain decimals such as 12.5.`)
  }
  const cards = [...(registered.get(entry.name)?.cards ?? [])]
  const card = Object.hasOwn(entry.input_schema.properties, "bid")
    ? cards.find(candidate => candidate.bid === input.bid.toLowerCase())
    : cards[0]
  if (!card) {
    return notSent(
      "Nothing was sent. This page has no card for that bid. Open the bid's page from autolaunch_my_positions and call again there.",
    )
  }
  return card.call(entry.name, input, signal)
}

function register(name: string, card: Card) {
  const current = registered.get(name)
  if (current) {
    current.cards.add(card)
    return
  }
  const entry = entries.get(name)
  const context = (document as Document & {modelContext?: ModelContext}).modelContext
  if (!entry || !context || typeof context.registerTool !== "function") return
  const lifetime = new AbortController()
  registered.set(name, {lifetime, cards: new Set([card])})
  void context
    .registerTool(
      {
        name: entry.name,
        title: entry.title,
        description: entry.description,
        inputSchema: entry.input_schema,
        annotations: entry.annotations,
        execute: (input, client) => execute(entry, input, client?.signal),
      },
      {signal: lifetime.signal},
    )
    .catch(() => {
      if (!lifetime.signal.aborted) console.warn(`Autolaunch tool unavailable: ${name}`)
    })
}

function unregister(name: string, card: Card) {
  const current = registered.get(name)
  if (!current) return
  current.cards.delete(card)
  if (current.cards.size > 0) return
  current.lifetime.abort()
  registered.delete(name)
}

const unreached = notSent(
  "Nothing was sent. The page lost its connection to the site before the wallet opened. Call again once the page has reconnected.",
)

/**
 * Makes a mounted card answer the tools it names. The hook settles each call
 * with the wallet's answer through `settle`; the server's refusal arrives as
 * `agent-tools:refused` and settles it with the card's own words. A call is
 * `preparing` until the hook starts a wallet press for it (`pressing`); only
 * the browser opens the wallet, so a preparing call the site can no longer
 * answer is known not to have sent anything.
 */
export function agentCard(hook: CardHook) {
  const names = (hook.el.dataset.agentTools ?? "").split(" ").filter(name => entries.has(name))
  const waiting = new Map<string, (outcome: AgentOutcome) => void>()
  const preparing = new Set<string>()

  const card: Card = {
    bid: hook.el.dataset.agentBid?.toLowerCase(),
    call(tool, input, signal) {
      if (signal?.aborted) return Promise.resolve(notSent("The call was cancelled before the page prepared anything."))
      const call = crypto.randomUUID()
      return new Promise(resolve => {
        const cancelled = () =>
          finish({
            outcome: "unknown",
            message:
              "The call was cancelled after the page began preparing it; the person's wallet may still ask them to confirm. Check the page or autolaunch_my_positions before calling again.",
          })
        const finish = (outcome: AgentOutcome) => {
          if (!waiting.delete(call)) return
          preparing.delete(call)
          signal?.removeEventListener("abort", cancelled)
          resolve(outcome)
        }
        waiting.set(call, finish)
        preparing.add(call)
        signal?.addEventListener("abort", cancelled)
        void hook.pushEventTo(hook.el, "agent_press", {call, tool, input}).then(
          results => {
            if (results.some(result => result.status === "rejected") && preparing.has(call)) finish(unreached)
          },
          () => {
            if (preparing.has(call)) finish(unreached)
          },
        )
      })
    },
  }

  hook.handleEvent("agent-tools:refused", payload => {
    const {component_id, call, message} = payload as {component_id: string; call: string; message: string}
    if (component_id === hook.el.id) waiting.get(call)?.(notSent(`Nothing was sent. ${message}`))
  })
  for (const name of names) register(name, card)

  return {
    // The hook is starting a wallet press for this call.
    pressing(agent: AgentCall | undefined) {
      if (agent) preparing.delete(agent.call)
    },
    settle(agent: AgentCall | undefined, outcome: AgentOutcome) {
      if (agent) waiting.get(agent.call)?.(outcome)
    },
    // The page lost the site: calls it was still preparing can no longer be answered.
    disconnected() {
      for (const call of [...preparing]) waiting.get(call)?.(unreached)
    },
    dispose() {
      for (const name of names) unregister(name, card)
      for (const finish of [...waiting.values()]) {
        finish({
          outcome: "unknown",
          message:
            "The page changed before the wallet answered, so the outcome is not known here. Check the person's wallet activity or autolaunch_my_positions before calling again.",
        })
      }
    },
  }
}

export type AgentCardHandle = ReturnType<typeof agentCard>
