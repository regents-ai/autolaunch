# Autolaunch browser tools

The deployed `/agents.md` is the signed-access guide. `priv/tool_manifest.json` is the source of registered native tools and their exact input schemas. Public tools omit cookies. Private reads and metadata writes use the shared `regent_agent_access` transport, an independent SIWA signer and current pairing. Browser owner credentials never become agent authority.

`prepare_agent_request` fixes the method, trusted origin, path and exact bytes before signing. Execute a signed operation with the prepared request, original input and fresh proof headers. No signer means no private tool execution. A missing response to a draft save has an unknown outcome; read the same draft before retrying. Pairing redemption requires a chosen agent name and real harness.

Person-controlled profile and wallet UI remains available, but its cookie and LiveView actions are not registered as agent tools. No native tool can launch, trade, stake, settle, claim, approve budgets or move funds.

Every page, Markdown document, refusal and API answer sends `Permissions-Policy: tools=(self)` and the WebMCP `Origin-Trial` token issued to https://autolaunch.sh (valid to 29 Mar 2027, set in `AutolaunchWeb.Endpoint`), so Chrome exposes `document.modelContext` on the live site without a flag. The token does nothing on localhost or another host; locally, turn on `chrome://flags/#enable-webmcp-testing`. Before the expiry, register a new token at Chrome's origin trials page and replace it there. After each release, `node scripts/webmcp-live.cjs` (from the repository root) confirms on the live site that Chrome turns WebMCP on, registers every site tool and runs a public read.

Native host acceptance is a separate verification step. Registered descriptors and local HTTP tests do not establish that Hermes, Grok or Muse can sign and execute successfully.
