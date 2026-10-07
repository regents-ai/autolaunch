defmodule AutolaunchWeb.ContentSecurityPolicy do
  @moduledoc """
  The content security policy the site's pages are served under, sent as
  `content-security-policy-report-only` while wallet flows are walked with it:
  the browser runs every page as before and names in its console each request
  the policy would have refused.

  Scripts, styles, fonts and pictures come from this site, requests and the live
  connection go back to it, no page is framed by another site, and forms submit
  only here. Every page can sign someone in from the top bar, so every page also
  allows what Privy's wallet sign-in loads, from Privy's published policy:
  Privy's API, frame and wallet RPC, Cloudflare Turnstile (when bot protection is
  on for the Privy app), WalletConnect's relays, verify frames, wallet list,
  logos and event reporting, Coinbase Wallet's relay, the `blob:` images
  Privy's window draws and the Regents mark it shows from regents.sh, the logo
  set for the shared Privy app. Privy's sign-in window writes its own style
  elements. Connected X accounts show their X profile picture.

  A page that loads anything else adds each origin to the one directive that
  needs it.
  """

  # The development code reloader runs in a frame from this site.
  @own_frames if Application.compile_env(:autolaunch, [AutolaunchWeb.Endpoint, :code_reloader]),
                do: ["'self'"],
                else: []

  @directives [
    {"default-src", ["'none'"]},
    {"script-src", ["'self'", "https://challenges.cloudflare.com"]},
    {"style-src", ["'self'", "'unsafe-inline'"]},
    {"img-src",
     [
       "'self'",
       "data:",
       "blob:",
       "https://regents.sh",
       "https://pbs.twimg.com",
       "https://explorer-api.walletconnect.com",
       "https://api.web3modal.org"
     ]},
    {"font-src", ["'self'"]},
    {"connect-src",
     [
       "'self'",
       "https://auth.privy.io",
       "https://*.rpc.privy.systems",
       "wss://relay.walletconnect.com",
       "wss://relay.walletconnect.org",
       "https://verify.walletconnect.org",
       "https://explorer-api.walletconnect.com",
       "https://api.web3modal.org",
       "https://rpc.walletconnect.org",
       "https://pulse.walletconnect.org",
       "wss://www.walletlink.org"
     ]},
    {"frame-src",
     @own_frames ++
       [
         "https://auth.privy.io",
         "https://verify.walletconnect.com",
         "https://verify.walletconnect.org",
         "https://challenges.cloudflare.com"
       ]},
    {"base-uri", ["'none'"]},
    {"form-action", ["'self'"]},
    {"frame-ancestors", ["'none'"]}
  ]

  @policy Enum.map_join(@directives, "; ", fn {directive, sources} ->
            Enum.join([directive | sources], " ")
          end)

  @doc "The policy every browser page is served under."
  def policy, do: @policy
end
