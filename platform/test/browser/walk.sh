#!/bin/sh
# The browser walk (make check-browser, npm run test:browser). It takes a port nothing
# on this machine is using, makes the run's database, named after the port,
# autolaunch_browser_<port>_test, and drops it when the walk ends, whatever
# happens: passed, failed, stopped, or a server that never started, when Playwright
# skips its own teardown. Arguments go to Playwright.
set -eu

port=$(node -e "const s = require('node:net').createServer().listen(0, '127.0.0.1', () => { console.log(s.address().port); s.close() })")
export MIX_ENV=test AUTOLAUNCH_WALK_PORT="$port" MIX_TEST_PARTITION="_browser_$port"
echo "The walk runs on port $port with its own database, autolaunch_browser_${port}_test."

drop() {
  status=$?
  mix run --no-start test/browser/support/drop.exs || status=1
  exit "$status"
}
trap drop EXIT
trap 'exit 130' INT TERM

mix db.setup
# The browser test server's pool, not the sandbox, so the pairings are kept.
AUTOLAUNCH_BROWSER_TEST=1 mix run --no-start test/browser/support/agents.exs
npx playwright test "$@"
