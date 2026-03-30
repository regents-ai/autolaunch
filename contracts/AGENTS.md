# Autolaunch Contracts Guide

This is the canonical contracts home for Autolaunch.

## Scope

- Put all Autolaunch Solidity contracts, Foundry scripts, and Foundry tests here.
- Keep the active Autolaunch architecture in this project, not in `monorepo/contracts`.
- For API <-> backend functionality, the source of truth is the Regent CLI contract surface. Start from `/Users/sean/Documents/regent/regent-cli/docs/api-contract-workflow.md`, `/Users/sean/Documents/regent/autolaunch/docs/api-contract.openapiv3.yaml`, `/Users/sean/Documents/regent/regent-cli/docs/regent-services-contract.openapiv3.yaml`, and `/Users/sean/Documents/regent/regent-cli/packages/regent-cli/src/contracts/api-ownership.ts`.
- Do not treat Phoenix route files or old CLI notes as the first place to define HTTP behavior. Change the contract files first, then make Autolaunch backend code and CLI code match.

## Project split

- `contracts/` for Autolaunch contracts
- `/Users/sean/Documents/regent/regent-cli` for Autolaunch CLI flows
- `autolaunch/` for Phoenix frontend and backend work

## Routing rule

- Do not add new Autolaunch launch, revenue, or emissions contracts back into `monorepo/contracts`.
- If a legacy contract exists there, port it here and extend it here.

## Outputs

- Keep deterministic deployment markers where they already exist:
  - `CCA_RESULT_JSON:`
