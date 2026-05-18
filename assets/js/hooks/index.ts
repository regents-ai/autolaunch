import type { HooksOptions } from "phoenix_live_view"

import { hooks as regentHooks } from "../regent"
import { AgentBookFlow } from "./agentbook-flow"
import { AutolaunchXmtpRoom } from "./autolaunch-xmtp-room"
import { AuctionsMarketMotion } from "./auctions-market-motion"
import { AutolaunchPrivyBridge } from "./wallet-bridge-privy-root"
import { AutolaunchWallet } from "./autolaunch-wallet"
import { HomeHeroMotion } from "./home-hero-motion"
import { MissionMotion } from "./mission-motion"
import { RegentStakingHook } from "./regent-staking"
import { ShellChrome } from "./shell-chrome"
import { SwapModal } from "./swap-modal"
import { WalletSwitchModal } from "./wallet-switch-modal"
import { WelcomeModal } from "./welcome-modal"
import { WalletTxButton } from "./wallet-tx-button"
import { XLinkFlow } from "./x-link-flow"

export const hooks: HooksOptions = {
  ...regentHooks,
  AgentBookFlow,
  AutolaunchXmtpRoom,
  AutolaunchPrivyBridge,
  AutolaunchWallet,
  AuctionsMarketMotion,
  HomeHeroMotion,
  MissionMotion,
  RegentStaking: RegentStakingHook,
  ShellChrome,
  SwapModal,
  WalletSwitchModal,
  WelcomeModal,
  WalletTxButton,
  XLinkFlow,
}
