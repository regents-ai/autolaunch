import type { HooksOptions } from "phoenix_live_view"

import { hooks as regentHooks } from "../regent"
import { AgentBookFlow } from "./agentbook-flow"
import { AutolaunchXmtpRoom } from "./autolaunch-xmtp-room"
import { AuctionsMarketMotion } from "./auctions-market-motion"
import { HomeHeroMotion } from "./home-hero-motion"
import { MissionMotion } from "./mission-motion"
import { PrivyAuth } from "./privy-auth"
import { ShellChrome } from "./shell-chrome"
import { WalletSwitchModal } from "./wallet-switch-modal"
import { WelcomeModal } from "./welcome-modal"
import { WalletTxButton } from "./wallet-tx-button"
import { XLinkFlow } from "./x-link-flow"

export const hooks: HooksOptions = {
  ...regentHooks,
  AgentBookFlow,
  AutolaunchXmtpRoom,
  AuctionsMarketMotion,
  HomeHeroMotion,
  MissionMotion,
  PrivyAuth,
  ShellChrome,
  WalletSwitchModal,
  WelcomeModal,
  WalletTxButton,
  XLinkFlow,
}
