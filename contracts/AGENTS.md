# Autolaunch Contracts Guide

This is the canonical contracts home for Autolaunch.

## Scope

- Put all Autolaunch Solidity contracts, Foundry scripts, and Foundry tests here.
- Keep the active Autolaunch architecture in this project, not in `monorepo/contracts`.
- For API <-> backend functionality, the source of truth is the Regents CLI contract surface. Start from `/Users/sean/Documents/regent/regents-cli/docs/api-contract-workflow.md`, `/Users/sean/Documents/regent/autolaunch/docs/api-contract.openapiv3.yaml`, `/Users/sean/Documents/regent/regents-cli/docs/regent-services-contract.openapiv3.yaml`, and `/Users/sean/Documents/regent/regents-cli/packages/regents-cli/src/contracts/api-ownership.ts`.
- Contract file meanings:
  - `api-contract.openapiv3.yaml` is the source of truth for a product's HTTP backend contract, including routes, auth, request bodies, response shapes, and stable error envelopes.
  - `regent-services-contract.openapiv3.yaml` is the source of truth for shared HTTP backend contracts that are not owned by one product, such as `regent-staking`.
  - `cli-contract.yaml` is the source of truth for a product's shipped CLI surface, including command names, flags/args, auth mode, whether a command is HTTP-backed or local/runtime-backed, and which backend contract operation it is allowed to use.
- Do not treat Phoenix route files or old CLI notes as the first place to define HTTP behavior. Change the contract files first, then make Autolaunch backend code and CLI code match.

## Project split

- `contracts/` for Autolaunch contracts
- `/Users/sean/Documents/regent/regents-cli` for Autolaunch CLI flows
- `autolaunch/` for Phoenix frontend and backend work

## Routing rule

- Do not add new Autolaunch launch, revenue, or emissions contracts back into `monorepo/contracts`.
- If a legacy contract exists there, port it here and extend it here.

## Outputs

- Keep deterministic deployment markers where they already exist:
  - `CCA_RESULT_JSON:`
