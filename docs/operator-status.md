# Autolaunch Operator Status

This document defines how Autolaunch should explain launch, subject, revenue, and operator state during stabilization.

Use it for launch pages, subject pages, the contract console, CLI-facing docs, release review, and future changes that touch launch execution or money movement.

## Operator Promise

Every Autolaunch operator surface should answer four questions:

- What happened?
- What is happening now?
- What needs action?
- What happens next?

If a page cannot answer those questions, the release is not ready.

## Status Model

| State | Meaning | Required next-action copy |
| --- | --- | --- |
| `live` | The auction, subject, revenue lane, claim, or staking path is usable now | Tell the person what action is available now |
| `pending` | Autolaunch has accepted the request and is waiting on launch work, chain state, or operator confirmation | Tell the person what is being checked and when to return |
| `needs-attention` | The operator, wallet owner, Safe signer, or human verifier must act | Name the actor, action, and surface to use |
| `failed` | The launch, transaction, auction, or verification did not complete | Say what did not complete and the recovery path |
| `preview` | The surface is visible but does not finalize money or launch state | Say what the preview can be used for and where the live action happens |

Use these states in docs and operator reasoning even when a page shows friendlier labels.

## Required Attention Areas

Autolaunch stabilization focuses on:

- Safe setup
- prelaunch plan validation
- hosted metadata publication
- deploy readiness
- launch job status
- auction status
- settlement and finalize guidance
- revenue splitter state
- ingress account state
- staking and claim state
- trust follow-up for ENS, X, World ID, and AgentBook
- contract-console prepared actions

Each area needs a clear next action or a clear "no action needed" state.

## Release Review

Before Autolaunch is included in a release:

- Confirm `mix autolaunch.doctor` is clean for the target environment.
- Confirm mock launch smoke passes for app-level launch-to-subject behavior.
- Confirm real launch jobs that reached `ready` pass deploy verification.
- Confirm launch status shows the current phase, history, and owner of the next action.
- Confirm finalize guidance separates deploy sanity from settlement completion.
- Confirm subject pages show recognized revenue, ingress state, staking state, claim state, and available actions.
- Confirm contract-console prepared actions name the required actor and do not look like normal wallet actions.
- Confirm trust follow-up names the next surface for ENS, X, World ID, and AgentBook.

## Copy Rules

Use customer-facing text that says what the person can do, what happens next, and why it matters.

Avoid explaining internal service names, route wiring, cache behavior, signing internals, old behavior, or compatibility plans in public UI text.

