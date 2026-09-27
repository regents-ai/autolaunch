// The page tools that press a wallet card for an agent (WebMCP,
// document.modelContext). A card names the tools it answers in
// `data-agent-tools`, and a settlement card names its bid in `data-agent-bid`;
// a tool is registered while a card on the page answers it. A call goes to the
// card's server side as an `agent_press`, which builds exactly the review the
// card's own button would send from and replies with it, and the call is sent
// at once, so it opens the person's wallet the same way a press does. Every
// call reaches the wallet, including one made while an earlier one is still
// with it.
import manifest from "../../priv/tool_manifest.json" with {type: "json"}

import type {Pressed, Review} from "./hooks/onchain_steps"
import type {Failure} from "./wallet_actions/send_step"

export type AgentOutcome =
  | {outcome: "sent"; transaction_hash: string; message: string}
  | {outcome: "not_sent"; message: string}
  | {outcome: "unknown"; message: string}

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
  pushEventTo(target: HTMLElement, event: string, payload: unknown): Promise<PromiseSettledResult<{reply: unknown}>[]>
}

const entries = new Map(
  (manifest.tools as unknown as Entry[]).filter(entry => entry.scope !== "site").map(entry => [entry.name, entry]),
)
const registered = new Map<string, {lifetime: AbortController; cards: Set<Card>}>()

const notSent = (message: string): AgentOutcome => ({outcome: "not_sent", message})

// Why nothing was sent, or may have been, in words for the agent to act on.
const failures: Record<Failure, AgentOutcome> = {
  wallet_unavailable: notSent(
    "Nothing was sent. The wallet active in this tab is not one on the person's account, or none is connected, so the page asked them to connect one. Call again once a wallet on their account is active.",
  ),
  step_unknown: notSent(
    "Nothing was sent. The page could not prepare this with those values. Check them against the page, then call again.",
  ),
  network_mismatch: notSent(
    "Nothing was sent. The person's wallet is on a different network. Ask them to switch it, then call again.",
  ),
  wallet_declined: notSent("The person declined in their wallet. Nothing was sent."),
  insufficient_funds: notSent(
    "Nothing was sent. The person's wallet doesn't have enough to pay the network fee on this network.",
  ),
  send_unconfirmed: {
    outcome: "unknown",
    message: "The wallet may have sent this. Ask the person to check their wallet activity before calling again.",
  },
}

function failed(reason: Failure): AgentOutcome {
  return failures[reason]
}

function sent(transaction_hash: string, remaining: string[]): AgentOutcome {
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

const replaced = notSent(
  "Nothing was sent. The page changed before the wallet opened. Call again on the page as it is now.",
)

/** The card's answer to an agent's call: the review to send from, or why there is none. */
type Reply = {review?: Review; send?: string; remaining?: string[]; message?: string}

/**
 * Makes a mounted card answer the tools it names. Each call asks the card's
 * server side for its review and sends the named step through `press`, the
 * same send a button press makes. A call is waiting on the site until the reply
 * arrives; only the browser opens the wallet, so a waiting call the site can no
 * longer answer is known not to have sent anything.
 */
export function agentCard(
  hook: CardHook,
  press: (review: Review, name: string) => Promise<Pressed>,
) {
  const names = (hook.el.dataset.agentTools ?? "").split(" ").filter(name => entries.has(name))
  const waiting = new Set<(outcome: AgentOutcome) => void>()

  const card: Card = {
    bid: hook.el.dataset.agentBid?.toLowerCase(),
    call(tool, input, signal) {
      if (signal?.aborted) return Promise.resolve(notSent("The call was cancelled before the page prepared anything."))
      return new Promise(resolve => {
        const finish = (outcome: AgentOutcome) => {
          if (!waiting.delete(finish)) return
          resolve(outcome)
        }
        waiting.add(finish)
        void hook.pushEventTo(hook.el, "agent_press", {tool, input}).then(
          ([result]) => {
            if (!waiting.has(finish)) return
            if (result?.status !== "fulfilled") return finish(unreached)
            const reply = (result.value.reply ?? {}) as Reply
            if (signal?.aborted) return finish(notSent("The call was cancelled before the wallet opened."))
            if (reply.message) return finish(notSent(`Nothing was sent. ${reply.message}`))
            if (!reply.review || !reply.send) return finish(failed("step_unknown"))
            // The wallet has it now: the call is answered by the wallet, not the site.
            waiting.delete(finish)
            void press(reply.review, reply.send).then(pressed =>
              resolve("transaction_hash" in pressed
                ? sent(pressed.transaction_hash, reply.remaining ?? [])
                : failed(pressed.reason)),
            )
          },
          () => finish(unreached),
        )
      })
    },
  }

  for (const name of names) register(name, card)

  return {
    // The page lost the site: calls still waiting on it can no longer be answered.
    disconnected() {
      for (const finish of [...waiting]) finish(unreached)
    },
    dispose() {
      for (const name of names) unregister(name, card)
      for (const finish of [...waiting]) finish(replaced)
    },
  }
}

export type AgentCardHandle = ReturnType<typeof agentCard>
