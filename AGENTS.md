# Autolaunch

Own autolaunch.sh and its product contracts in this monorepo.

- Root `src/`, `bin/`, `requirements/` and related directories are the frozen V1
  contract project. Preserve its paths, pinned identities and existing gates.
- `cli/` owns the independently installable public `autolaunch` command. Run
  `npm run check`, `npm run test:parity` and `npm run check:contract` there.
- `platform/` is the Phoenix/Ash website; run Mix/npm from there. Its `contracts/`
  folder contains runtime manifests and ABIs, not the root Solidity sources.
- `revenue-mesh/` is a separate Foundry component within this repository.
- Follow Control's `regent-workflow` and one integrating owner. Verify the changed
  component and necessary cross-component paths, preserving unrelated working edits.
- Contract gates, signing, wallet actions and release approvals keep their existing
  boundaries. Every wallet-button press reaches the wallet. Never read `.env`,
  `.env.local` or `.envrc`; no publishing, production access or deployment without
  applicable founder authority.
