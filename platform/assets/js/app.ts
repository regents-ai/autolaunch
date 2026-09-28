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
import {AutolaunchBidSettlement} from "./hooks/autolaunch_bid_settlement"
import {AutolaunchBidWallet} from "./hooks/autolaunch_bid_wallet"
import {AutolaunchLaunchWallet} from "./hooks/autolaunch_launch_wallet"
import {AutolaunchReviewedSteps} from "./hooks/autolaunch_reviewed_steps"
import {AutolaunchSubjectWallet} from "./hooks/autolaunch_subject_wallet"
import {AutolaunchSwapDialog} from "./hooks/autolaunch_swap_dialog"
import {ImageGradient} from "./hooks/image_gradient"
import {PriceChart} from "./hooks/price_chart"
import {SiteSearch} from "./hooks/site_search"
import {installCopyButtons} from "./copy_buttons"
import {CreatorConnections} from "./hooks/creator_connections"
import {XConnections} from "./hooks/x_connections"
import {Optics} from "./optics_controller.js"
import {installMotion} from "./motion/page"
import {Toast} from "./motion/toast"
import {installPublicTools} from "./public_tools"
import {installRegentTokenMenu} from "./regent_token_menu"
import {installTheme} from "./theme"

const hooks = {
  ...colocatedHooks,
  AutolaunchBidSettlement,
  AutolaunchBidWallet,
  AutolaunchLaunchWallet,
  AutolaunchReviewedSteps,
  AutolaunchSubjectWallet,
  AutolaunchSwapDialog,
  ImageGradient,
  PriceChart,
  Optics,
  XConnections,
  CreatorConnections,
  SiteSearch,
  Toast,
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
installMotion()
installRegentTokenMenu()
installCopyButtons()
installTheme()
installAccountAuthLazyLoader()
installCrossTabCsrf()
installPublicTools()

// Exposed for the browser console: liveSocket.enableDebug(), enableLatencySim().
window.liveSocket = liveSocket
