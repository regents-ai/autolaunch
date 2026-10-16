import "../css/app.css"
import "../vendor/regent_ui/blog.mjs"

import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/autolaunch"

import {
  browserCsrfToken,
  holdSocketDuringCookieRotation,
  installAccountAuthLazyLoader,
  installCrossTabCsrf,
  type PinnedSocket,
} from "./auth_lazy"
import {AutolaunchSwapDialog} from "./hooks/autolaunch_swap_dialog"
import {ImageGradient} from "./hooks/image_gradient"
import {OnchainSteps} from "./hooks/onchain_steps"
import {SearchDialog} from "./hooks/search_dialog"
import {PriceChart} from "./hooks/price_chart"
import {installAgentTools} from "./agent_tools"
import {installCopyButtons} from "./copy_buttons"
import {CreatorConnections} from "./hooks/creator_connections"
import {XConnections} from "./hooks/x_connections"
import {mountMotion} from "./motion"
import {MotionCascade, MotionTabs} from "./hooks/motion/reveals"
import {MotionCount, MotionRefusal} from "./hooks/motion/moments"
import {MotionPanels} from "./hooks/motion/slides"
import {Toast} from "./motion/toast"
import {installPublicTools} from "./public_tools"
import {installRegentTokenMenu} from "./regent_token_menu"
import {installShellPanels} from "./shell_panels"
import {installTheme} from "./theme"
import {SiteButtons, SiteLight} from "./hooks/site_buttons"
import {TradeViews} from "./hooks/trade_views"

// The motion lab's own hooks load only on its page.
const labHooks = window.location.pathname === "/animations"
  ? (await import("./motion_lab")).hooks : {}
const hooks = {
  ...labHooks,
  ...colocatedHooks,
  AutolaunchSwapDialog,
  ImageGradient,
  OnchainSteps,
  PriceChart,
  XConnections,
  CreatorConnections,
  SearchDialog,
  Toast,
  MotionCascade,
  MotionCount,
  MotionPanels,
  MotionRefusal,
  MotionTabs,
  SiteButtons,
  SiteLight,
  TradeViews,
}
if (!browserCsrfToken()) throw new Error("Missing CSRF token")

// Sign in and refresh renew the session and rotate its CSRF state, so every
// connection and reconnection reads the token the browser holds now.
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({_csrf_token: browserCsrfToken()}),
  hooks,
})

// Installed before the first connect, so even the page's opening attempt is
// subject to the barrier. `types.d.ts` describes only the LiveSocket surface
// this application calls, so the transport entry point is named at the cast.
holdSocketDuringCookieRotation(liveSocket.getSocket() as PinnedSocket)
liveSocket.connect()
mountMotion(document)
// A press dispatches these to open or close the dialog it names.
document.addEventListener("autolaunch:open-dialog", event => {
  if (event.target instanceof HTMLDialogElement) event.target.showModal()
})
document.addEventListener("autolaunch:close-dialog", event => {
  if (event.target instanceof HTMLDialogElement) event.target.close()
})
installRegentTokenMenu()
// A page drawn after navigation starts with its panel toggles closed; they follow the panel.
const shellPanels = installShellPanels()
window.addEventListener("phx:page-loading-stop", shellPanels.sync)
installCopyButtons()
installAgentTools()
installTheme()
installAccountAuthLazyLoader()
installCrossTabCsrf()
installPublicTools()

// A panel names a field to focus once the page shows its new figures: a box
// already focused would keep what it held.
window.addEventListener("phx:autolaunch:focus", event => {
  document.getElementById((event as CustomEvent<{to: string}>).detail.to)?.focus()
})

// Exposed for the browser console: liveSocket.enableDebug(), enableLatencySim().
window.liveSocket = liveSocket
