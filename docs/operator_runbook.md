# Autolaunch Operator Runbook

The cross-repo launch and testing runbook now lives here:

- `/Users/sean/Documents/regent/docs/regent-local-and-fly-launch-testing.md`

Use the guide's **Autolaunch Local And Fly Deploy** and **Contract Deployment And Verification** sections for:

- shared infrastructure deploys
- per-launch deploy verification
- local and Fly app checks
- `mix autolaunch.doctor`
- `mix autolaunch.beta_check`
- `AUTOLAUNCH_MOCK_DEPLOY=true mix autolaunch.smoke`
- `mix autolaunch.verify_deploy --job <job-id>`

Keep these Autolaunch-specific references close:

- Product rules: `/Users/sean/Documents/regent/autolaunch/docs/product_invariants.md`
- Operator status wording: `/Users/sean/Documents/regent/autolaunch/docs/operator-status.md`
- Contract overview: `/Users/sean/Documents/regent/autolaunch/contracts/README.md`
- Contract architecture: `/Users/sean/Documents/regent/autolaunch/contracts/docs/ARCHITECTURE_GUIDE.md`
- Techtree evidence packet: optional supporting evidence on prelaunch plans; verify it in Techtree and do not treat it as a launch gate.

For this beta, `$REGENT` staking is Base mainnet and Autolaunch launch rehearsal is Base.
