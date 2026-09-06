# Autolaunch contracts

Two independent Foundry projects. Each is verified from its own directory, and neither reads
the other's sources or build output.

| Component | Purpose | Verify |
| --- | --- | --- |
| [v1/](v1/README.md) | The founder-frozen Autolaunch V1 auction system: specification, Solidity, requirement ledger, frozen release surface, deployment packet, and the three gates that decide whether the proofs still hold. Nothing in it is deployed. | `cd v1 && bin/gate.sh`, offline, after the one-time setup in its README |
| [revenue-mesh/](revenue-mesh/README.md) | The offline CCTP foundation for immutable USDC revenue routes into a Base `PaymentReceiverV1`. Every route it produces is an unverified, inactive candidate. | `cd revenue-mesh && forge fmt --check && forge build && forge test --offline` |

`v1/` pins its dependency closure as Git submodules. They are declared in the repository's
top-level `.gitmodules` at `contracts/v1/lib/...` and materialized only for contract work; see
[v1/README.md](v1/README.md#setup). `revenue-mesh/` has no external dependencies.

The V1 gate proves that the whole repository, not only `v1/`, is one clean Git object, so
run it on a committed tree without build output elsewhere in the checkout.

The website's runtime copies of the V1 ABIs and chain manifest live in
[`platform/contracts/`](../platform/contracts/). They are consumers of this directory, not
sources.
