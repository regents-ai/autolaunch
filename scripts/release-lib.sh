# shellcheck shell=bash
# Shared by scripts/deploy.sh and scripts/rollback.sh, which source it from the
# repository root with $app, $root and $dry_run set. Never run on its own.

# The public address where an app says which commit it runs: `ok <full commit>`.
health_address() {
  case "$1" in
    autolaunch-sh) echo "https://autolaunch.sh/healthz" ;;
    *)
      echo "Refusing: no health address is known for the app \"$1\"." >&2
      return 1
      ;;
  esac
}

# Prints the full commit the site at health address $1 runs. Refuses when the
# address cannot be read, names no commit, or names one this checkout lacks.
live_commit() {
  local answer live
  if ! answer="$(curl -fsS --max-time 20 "$1")"; then
    echo "Refusing: $1 could not be read, so the live commit is unknown." >&2
    return 1
  fi
  live="${answer#ok }"
  if [[ ! $live =~ ^[0-9a-f]{40}$ ]]; then
    echo "Refusing: $1 answered \"${answer:0:80}\", which names no commit." >&2
    return 1
  fi
  if ! git -C "$root" cat-file -e "$live^{commit}" 2>/dev/null; then
    echo "Refusing: $1 names the live commit $live, which this checkout does not hold." >&2
    return 1
  fi
  echo "$live"
}

# Runs a command, or with --dry-run prints it exactly as it would run.
run() {
  if [[ -n $dry_run ]]; then
    printf 'Would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# Switches $app to the image $1. Every site shares one production database, and
# a switch briefly doubles a site's connections. Two switches fit at once across
# all sites, so this takes the first shared place if it is free and otherwise
# waits for the second. It runs in the folder that holds platform/fly.toml and
# the deployment/ descriptions fly.toml's [[files]] place on the machine.
switch_to() {
  local place=/tmp/regent-shared-db-release.lock
  lockf -k -s -t 0 "$place" true || place=/tmp/regent-shared-db-release-2.lock
  echo "==> Switching $app to $1 (waits for $place if it is taken)"
  run lockf -k "$place" fly deploy \
    --config platform/fly.toml \
    --app "$app" \
    --ha=false \
    --image "$1"
}
