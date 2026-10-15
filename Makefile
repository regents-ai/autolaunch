.PHONY: help check check-platform check-required-fixes check-cli readiness
help:
	@echo "Run make check for every gate, or check-platform, check-required-fixes or check-cli for one."
	@echo "Run make readiness to start the local server and check what the agent-readiness scorer looks for."
check: check-platform check-required-fixes check-cli
check-platform:
	cd platform && mix precommit && npm run typecheck && npm test
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
REGENTS_CLI_REV := d1f16ae8ce7ecb086eb7c313285d67fc420107a2
check-cli:
	uv run --no-project --with "regents-cli[check] @ git+https://github.com/regents-ai/regents-cli@$(REGENTS_CLI_REV)" \
	  python -m regents_cli.check_commands cli/commands.json cli/docs/profile.openapi.json cli/docs/api-contract.openapiv3.yaml
# Starts the local server on a free port, checks what the agent-readiness scorer
# looks for, then stops the server.
readiness:
	scripts/readiness.sh
