.PHONY: help check check-platform check-required-fixes check-cli check-siwa-latest readiness
help:
	@echo "Run make check for every gate, or check-platform, check-required-fixes, check-cli or check-siwa-latest for one."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
check: check-platform check-required-fixes check-cli check-siwa-latest
# The platform check (mix precommit) ends with the TypeScript check.
check-platform:
	cd platform && mix precommit
# Every site runs the same check against ash-template's current main branch, so a
# newly published required fix reaches every site's next gate. Needs `gh auth login`.
TEMPLATE := repos/regents-ai/ash-template
check-required-fixes:
	cd platform && mkdir -p _build && rev=$$(gh api $(TEMPLATE)/commits/main --jq .sha) \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/platform/scripts/check_required_fixes.exs?ref=$$rev" > _build/check_required_fixes.exs \
	&& gh api -H "Accept: application/vnd.github.raw" "$(TEMPLATE)/contents/security/required-fixes.json?ref=$$rev" > _build/required-fixes.json \
	&& elixir _build/check_required_fixes.exs "ash-template $$rev" < _build/required-fixes.json
# The command description check is regents-cli's own checker at the commit pinned
# here, run by uv straight from GitHub. Move the pin in a commit.
REGENTS_CLI_REV := c12d8563c46e8b5229e32db76c1a104fb469b7b7
check-cli:
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json cli/docs/api-contract.openapiv3.yaml \
	  platform/contracts/covered-calls.openapiv3.yaml platform/contracts/exposure.openapiv3.yaml \
	  platform/contracts/earn.openapiv3.yaml
# Fails unless the site is on the newest SIWA on both sides: the newest regents-cli
# (the pin above and the documents) and, at the elixir-utils commit
# platform/mix.exs pins, the same SIWA library folder as on elixir-utils main (the
# folder is compared, not the history). Needs `gh auth login`.
check-siwa-latest:
	scripts/check-siwa-latest.sh $(REGENTS_CLI_REV)
# Starts the local server on a free port, checks what the agent-readiness scorer
# looks for, then stops the server.
readiness:
	scripts/readiness.sh
