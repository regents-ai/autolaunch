/**
 * Every value card's panel, by the name its card carries in `data-value-card`.
 * This list and `panels/` are Autolaunch's own; the six cards sit on the home
 * page under "Principles".
 */
import {address} from "./panels/address"
import {blocks} from "./panels/blocks"
import {clearing} from "./panels/clearing"
import {handoff} from "./panels/handoff"
import {signature} from "./panels/signature"
import {vault} from "./panels/vault"
import type {ValuePanel} from "./panel"

export const panels: Record<string, ValuePanel> = {
  clearing,
  vault,
  address,
  signature,
  handoff,
  blocks,
}
