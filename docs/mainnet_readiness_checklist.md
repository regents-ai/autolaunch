# Autolaunch Mainnet Readiness Checklist

This checklist tracks the hardening items that matter before Ethereum mainnet launch operations.

Status key:

- `[x]` complete
- `[ ]` still open

## Contract safety and launch invariants

- [x] Lock down `LaunchDeploymentController.deploy(...)` so an authorized controller cannot be driven by arbitrary callers.
- [x] Emit an onchain deployment event from the launch controller so the deployed stack has a durable audit trail.
- [x] Enforce the intended sweep rule in `RegentLBPStrategy` so post-auction sweeps cannot replace migration.
- [x] Keep the migration path under the strongest Foundry coverage in the repo.
- [x] Remove the accidental native-ETH sink from `LaunchFeeVault`.
- [x] Move the shared `Owned` helper to a two-step transfer model.

## Operational wiring

- [x] Preserve the shared-infra ownership handoff from `SubjectRegistry` to `RevenueShareFactory` under the new two-step model.
- [x] Expose or document the acceptance step for any pending post-launch ownership handoffs to the Agent Safe.

## Product-story consistency

- [x] Freeze the canonical product rules in one document.
- [x] Make the repo docs match the canonical rules:
  - Base-family USDC only for recognized subject revenue
  - 10% / 5% / 85% allocation story
  - CLI-first launch, browser-first participation
  - ingress as receive-and-sweep wrapper only
- [x] Make the launch and guide pages match the same story.

## Validation

- [x] Run the full Foundry contract test suite after the hardening pass.
- [x] Run the app-side validation that is reasonable for these changes.
