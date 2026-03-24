import type { HooksOptions } from "phoenix_live_view"

import { AgentBookFlow } from "./agentbook-flow"
import { AuctionGuideMotion } from "./auction-guide-motion"
import { LaunchForm } from "./launch-form"
import { MissionMotion } from "./mission-motion"
import { PrivyAuth } from "./privy-auth"
import { WalletTxButton } from "./wallet-tx-button"

export const hooks: HooksOptions = {
  AgentBookFlow,
  AuctionGuideMotion,
  LaunchForm,
  MissionMotion,
  PrivyAuth,
  WalletTxButton,
}
