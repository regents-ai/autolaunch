#!/usr/bin/env bash
# Fails unless this site is on the newest SIWA on both sides (Sean, 28 Oct 2026:
# "all sites should always be on the latest of siwa-server, forcibly"): the
# newest published regents-cli, which agents install to sign in and sign their
# requests, and the newest change to the SIWA library the server checks those
# requests with. Both are read from their sources on every run, so a new release
# stops every site's next gate until the site moves to it.
#
#   scripts/check-siwa-latest.sh <the Makefile's REGENTS_CLI_REV>
#
# regents-cli: the pin is the newest release's tag commit; the public documents
# name the release, that commit and the wheel's SHA256 (platform/lib/autolaunch_web/
# public_documents.ex is where they are kept; the documents carry a placeholder);
# the agent journeys install the CLI from the same commit; no install line names
# another release. The SIWA library: the
# elixir-utils commit platform/mix.exs pins contains the newest commit that
# changed siwa/siwa-elixir/apps/siwa on elixir-utils main. Needs `gh auth login`
# and curl.
set -euo pipefail

# Where this site keeps them. The release every public document names lives in
# one place, public_documents.ex (the documents carry only a placeholder for it),
# and the journeys install the same CLI from the commit scripts/agent-journeys.sh pins.
documents=platform/lib/autolaunch_web/public_documents.ex
install_lines=(platform/lib/autolaunch_web/public_documents platform/lib/autolaunch_web/public_documents.ex)
journeys=scripts/agent-journeys.sh
pin=$1
read -r latest wheel < <(curl -fsS https://pypi.org/pypi/regents-cli/json | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(d["info"]["version"], next(u["digests"]["sha256"] for u in d["urls"] if u["packagetype"] == "bdist_wheel"))')
tag=$(gh api "repos/regents-ai/regents-cli/commits/v$latest" --jq .sha)
utils=$(sed -nE 's/^ *@elixir_utils_ref "([0-9a-f]{40})"$/\1/p' platform/mix.exs)
siwa=$(gh api "repos/regents-ai/elixir-utils/commits?path=siwa/siwa-elixir/apps/siwa&sha=main&per_page=1" --jq '.[0].sha')

failed=0
fail() {
  printf '%s\n' "$1" >&2
  failed=1
}

[ "$pin" = "$tag" ] ||
  fail "regents-cli $latest is the newest release: move REGENTS_CLI_REV in the Makefile from $pin to $tag."
for word in "version: \"$latest\"" "commit: \"$tag\"" "wheel_sha256: \"$wheel\""; do
  grep -qF "$word" "$documents" ||
    fail "regents-cli $latest is the newest release: $documents does not name $word."
done
journeys_rev=$(sed -nE 's/^REGENTS_CLI_REV=([0-9a-f]{40})$/\1/p' "$journeys")
[ "$journeys_rev" = "$tag" ] ||
  fail "regents-cli $latest is the newest release: move REGENTS_CLI_REV in $journeys from ${journeys_rev:-nothing} to $tag."
stale=$(grep -rnoE 'regents-cli==[0-9]+(\.[0-9]+)*' "${install_lines[@]}" | grep -vE "==${latest//./\\.}\$" || true)
[ -z "$stale" ] || fail "regents-cli $latest is the newest release: these install lines name another release:
$stale"

if [ -z "$utils" ]; then
  fail "platform/mix.exs has no @elixir_utils_ref \"<40-character commit>\" line to check."
else
  case $(gh api "repos/regents-ai/elixir-utils/compare/$siwa...$utils" --jq .status) in
    identical | ahead) ;;
    *) fail "elixir-utils $siwa is the newest SIWA library change: move @elixir_utils_ref in platform/mix.exs from $utils to a commit that contains it." ;;
  esac
fi

exit "$failed"
