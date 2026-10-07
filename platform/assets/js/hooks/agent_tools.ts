import type {Hook} from "../hook_composition"
import {agentPage} from "../agent_wallet_tools"

type AgentToolsHook = Hook & {
  el: HTMLElement
  pushEventTo(target: HTMLElement, event: string, payload?: unknown): Promise<PromiseSettledResult<{reply: unknown}>[]>
  tools?: ReturnType<typeof agentPage>
}

/**
 * An element whose `data-agent-tools` names page tools that open no wallet,
 * such as a form an agent reads and fills; its server side answers each call
 * as an `agent_call`.
 */
export const AgentTools: Hook = {
  mounted(this: AgentToolsHook) {
    this.tools = agentPage(this)
  },

  destroyed(this: AgentToolsHook) {
    this.tools?.dispose()
  },
}
