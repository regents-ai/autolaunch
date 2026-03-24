# Autolaunch Contracts Guide

This is the canonical contracts home for Autolaunch.

## Scope

- Put all Autolaunch Solidity contracts, Foundry scripts, and Foundry tests here.
- Keep the active Autolaunch architecture in this project, not in `monorepo/contracts`.

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
  - `MAINNET_REGENT_EMISSIONS_RESULT_JSON:`
  - `REGENT_EMISSIONS_RESULT_JSON:`
