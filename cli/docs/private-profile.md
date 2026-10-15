# Private shared profile API v1

`profile get` → GET `/api/v1/profile`; `profile sync` → POST `/api/v1/profile/sync`;
`profile update` → PATCH `/api/v1/profile`. These standalone CLI commands use
the owner's Privy credentials. Profile operations are not registered as native
browser tools or exposed through the unified CLI's paired-agent commands.

Pipe one JSON object with exactly `access` and `identity` from an approved Privy
credential provider. Never pass tokens as flags, copy cookies, or use SIWA or
publication keys as substitutes. This adapter does not obtain a Privy session.
Help and public commands never read the pipe. Private commands ignore public
origin environment variables; an alternate origin requires explicit `--base-url`.
No redirects, saved proof, automatic retries, wallet signatures or payment grants.

Updates accept `--display-name`, `--wallet-address`, or `--clear-wallet true`.
An uncertain write returns `outcome_unknown: true`; read before deciding to retry.
Profiles are owner-only and X verification describes the last synchronized signed
Privy evidence. It is not a company X role or payment eligibility.
