# WIP state — Autolaunch v1 ceremony Phase 0 (branch feat/autolaunch-ceremony-phase0, base 25f5b59)

## Design (fixed 2026-09-22, second writer session)

- Eighth address: `lpLocker = vm.computeCreateAddress(strategy, 1)`. It is added to `DeployAutolaunchV1.Graph`
  (script/, not src/), `predict` derives it, `execute` reads `strategy.lpLocker()` back, so `--rehearse`
  (forge script simulation) proves it as well as the tests.
- DEP-071 proves: strategy at factory nonce 1, hook CREATE2, factory nonce 3, locker at strategy nonce 1,
  strategy nonce 2, and every other created contract at nonce 1 (nothing else creates anything).
- DEP-072 adds: `strategy.lpLocker()` == prediction, `locker.strategy()` == strategy, locker runtime code
  byte-identical to a reference `new RevstakeLPLocker(strategy)` from the same build (the masked comparison
  against the frozen artifact happens in `bin/ceremony.py record`, where immutable references exist).
- DEP-074 reports RevstakeLPLocker margins (creation code + abi.encode(strategy)); the gate reconciles it
  against the existing RevstakeLPLocker row in reports/frozen/deployable-sizes.json.
- Gate: PREDICTED gains `lp_locker`; INTERNAL_ORDER = strategy, locker, hook (temporal order); internal
  entries carry `created_by` (creator contract) and `creator_nonce` for CREATE (one canonical key, replacing
  `factory_nonce`); `excluded` drops "liquidity locker"; counts say eight / four-of-eight constructors.
- Manifest section of the gate imports `verify_manifest` from bin/ceremony.py: exactly two states, the
  canonical empty record or a deployed record whose digest equals the installed packet's and whose eight
  addresses equal the predictions.
- `contracts/v1/bin/ceremony.py` (stdlib): `record` and `site-config`, modelled on contracts/stocks/bin/ceremony.py.
- Hermetic proof: fresh Anvil `--chain-id 8453 --auto-impersonate` on a free port (never 50745/53203/53991/56513/4050/4062),
  five `eth_sendTransaction` creations posted by urllib from the packet deployer at nonce 0 (no keys, no cast send,
  no forge broadcast), then `record` and `site-config` against it with REGENT_BASE_RPC_URL pointed at that Anvil.
  Script: scratchpad/hermetic-ceremony.py.

## Commits on the branch (all with the Fable trailer)

- 7e2a5b5 v1: cover the LP locker as the ceremony's eighth predicted address (A: script, tests, gate, ledger, docs)
- 3ab77c3 v1: keep the packet's code-identity note ASCII
- abecd0e v1: install the packet that predicts the LP locker (A4: candidate from --prepare at 3ab77c3, READMEs)
- 2034564 v1: record the ceremony and render the site-config from confirmed receipts (B+C: ceremony.py, gate
  manifest section, canonical empty manifest, docs)
- b901130 stocks: describe the executor in the Base mainnet runbook (D)
- 22e94fd v1: never leave a bytecode cache behind the ceremony tool (the gate's import of bin/ceremony.py wrote
  bin/__pycache__, which bin/gate.sh's clean-tree check rejects; both now run with bytecode writing off)

## Ceremony facts

- New digest 0x5ba245ed0af9de1c1749f0b50cd54919a8084faf580d92282ef0592144f35327 installed; old
  0x5548e545551bca298bbf8e878da23ffe2c7be147939c1033ed65ad6acb184521 retired.
- Deployer 0x9b2C414614aEE294202c1219520955EF3B596031, nonce 0, salt ends 1bc5, prepared at Base block 51657720.
- Eight addresses: first seven unchanged; lp_locker 0xBdC4b69bfd66aCDb8b794bADbEf3a50a14891159 (independently
  re-derived by RLP CREATE from strategy nonce 1).
- Rehearsal (abecd0e, clean clone) forge estimates per creation (gas limits, 130% of simulated use):
  UERC20Factory 3,631,821; Escrow 1,374,206; Splitter 1,869,721; Receiver 1,170,936; Factory 10,196,197;
  "Estimated total gas used for script: 18242881". Hermetic Anvil (cancun) actual gas used:
  2,793,709 / 1,057,082 / 1,438,247 / 900,720 / 7,843,229 = 14,032,987.
- Nothing signed, broadcast, pushed or installed beyond the packet candidate.

## Evidence (scratchpad/evidence/)

- prepare-3ab77c3.log, packet-candidate-3ab77c3.json, offline-abecd0e.log, rehearse-abecd0e.log,
  forge-script-dry-run-abecd0e.log, dry-run-run-latest-abecd0e.json, hermetic-run.log, hermetic/.
- final-b901130-slither-0.11.6-failed/: first final run; bin/gate.sh failed its frozen-identity check because the
  machine's `slither` (uv tool, ~/.local/bin) is 0.11.6 while requirements/frozen-identity.json pins 0.11.5; every
  later gate then failed for the missing dependency receipt. Environment, not the branch.
- scratchpad/slither-0.11.5/: `uv venv` + `uv pip install --offline slither-analyzer==0.11.5` from the uv cache (no
  download). Putting its whole bin on PATH shadowed python3 (3.12 vs the frozen 3.14.7, evidence
  final-22e94fd-venv-python-failed/), and a symlink shim failed too because the uv launcher's shebang is /bin/sh for a
  long path and the gate reads that shebang to find the detector interpreter (final-22e94fd-symlink-shim-failed/).
  scratchpad/slither-shim/slither is now a tiny launcher whose shebang is the venv python; that dir goes first on PATH
  for gate runs, as earlier lanes did with their slither shim.
- final-b901130-pycache-failed/: re-run with pinned Slither; bin/gate.sh failed on `!! contracts/v1/bin/__pycache__`
  left by an earlier deployment-gate run's import of ceremony.py. Fixed in 22e94fd.
- final-22e94fd/: the final run (scratchpad/final-gates-22e94fd.sh, pinned Slither first on PATH): gate.log,
  fork-check.log, fork-evidence-sha256.txt, deployment-offline.log, deployment-rehearse.log, dry-run-run-latest.json,
  hermetic.log, hermetic/, summary.txt.

## Final result (2026-09-22, clean clone at 22e94fd)

- bin/gate.sh GATE PASS; bin/fork-gate.sh check FORK GATE PASS; deployment-gate --offline and --rehearse DEPLOYMENT GATE
  PASS (mainnet NO-GO); hermetic proof exit 0 (re-run after fixing the proof script's own bytecode cache; the first run's
  evidence is hermetic-first-run/). Evidence: scratchpad/evidence/final-22e94fd/. Clean clone left with no dirty or
  ignored path beyond the usual build outputs. Report delivered to the owner.
