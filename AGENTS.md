# Autolaunch

Own autolaunch.sh and its product contracts in this monorepo.

- `contracts/v1/` is the frozen V1 contract project. Run its gates from that
  directory; they prove the root is exactly `contracts/v1` under the Git top level
  and that the whole repository is clean. Preserve its pinned identities, frozen
  records and existing gates. Its submodules are declared in the top-level
  `.gitmodules` at `contracts/v1/lib/...`.
- `cli/` owns the independently installable public `autolaunch` command. Run
  `npm run check`, `npm run test:parity` and `npm run check:contract` there.
- `platform/` is the Phoenix/Ash website; run Mix/npm from there. Its `contracts/`
  folder contains runtime manifests and ABIs, not the root Solidity sources.
- `contracts/revenue-mesh/` is a separate Foundry component with no external
  dependencies; verify it from its own directory. `contracts/stocks/` is the Stocks
  launch component; it exports pinned dependencies with its `bootstrap-deps.py` and
  never edits `contracts/v1/`. `contracts/README.md` is the map.
- `plugins/` holds no implementation yet; its README points at the CLI and WebMCP
  contract a plugin would wrap. Do not imply a published plugin.
- Follow Control's `regent-workflow` and one integrating owner. Verify the changed
  component and necessary cross-component paths, preserving unrelated working edits.
- Contract gates, signing, wallet actions and release approvals keep their existing
  boundaries. Every wallet-button press reaches the wallet. Never read `.env`,
  `.env.local` or `.envrc`; no publishing, production access or deployment without
  applicable founder authority.

For product orientation and related Regent products, see [README.md](README.md).
The public agent entry point is [platform/priv/static/llms.txt](platform/priv/static/llms.txt);
keep its advertised commands consistent with the owning CLI and HTTP contracts.
