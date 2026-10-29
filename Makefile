.PHONY: help check check-platform check-browser check-required-fixes check-cli check-siwa-latest readiness
help:
	@echo "Run make check for every gate, or check-platform, check-browser, check-required-fixes, check-cli or check-siwa-latest for one."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
check: check-platform check-required-fixes check-cli check-siwa-latest
# The platform check ends with the browser walk.
check-platform:
	cd platform && mix precommit && npm run typecheck && npm test && npm run test:browser
# The browser walk alone (platform/test/browser): the layout checks at phone and
# desktop width. It starts its own server on its own database.
check-browser:
	cd platform && npm run test:browser
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
REGENTS_CLI_REV := 0e3768f5b92fe8210fb00fea0053bcb5e9c2afaf
check-cli:
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json cli/docs/profile.openapi.json cli/docs/api-contract.openapiv3.yaml
# Fails unless the site is on the newest SIWA on both sides: the newest regents-cli
# (the pin above, the documents and the journeys) and the newest change to the SIWA
# library in the elixir-utils commit platform/mix.exs pins. Needs `gh auth login`.
check-siwa-latest:
	scripts/check-siwa-latest.sh $(REGENTS_CLI_REV)
# Starts the local server on a free port, checks what the agent-readiness scorer
# looks for, then stops the server.
readiness:
	scripts/readiness.sh
