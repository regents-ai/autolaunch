# Autolaunch browser tools

The deployed `/agents.md` is the signed-access guide. `priv/tool_manifest.json` is the source of registered native tools and their exact input schemas. Public tools omit cookies. Private reads and metadata writes use the shared `regent_agent_access` transport, an independent SIWA signer and current pairing. Browser owner credentials never become agent authority.

`prepare_agent_request` fixes the method, trusted origin, path and exact bytes before signing. Execute a signed operation with the prepared request, original input and fresh proof headers. No signer means no private tool execution. A missing response to a draft save has an unknown outcome; read the same draft before retrying. Pairing redemption requires a chosen agent name and real harness.

Person-controlled profile and wallet UI remains available, but its cookie and LiveView actions are not registered as agent tools. No native tool can launch, trade, stake, settle, claim, approve budgets or move funds.

Native host acceptance is a separate verification step. Registered descriptors and local HTTP tests do not establish that Hermes, Grok or Muse can sign and execute successfully.
