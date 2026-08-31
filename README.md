# Autolaunch RevenueMesh

This repository contains the offline EVM CCTP foundation for immutable USDC revenue routes into an
existing Base `PaymentReceiverV1` and its bound splitter.

The source factory fixes one source USDC token, Circle TokenMessenger V2, source domain, source
namespace and chain identity, minimum sweep, per-message burn cap, and fee ceiling. A route deployer
supplies only the Base receiver and Base splitter. The resulting inbox has no owner, role, proxy,
pause, rescue, withdrawal, arbitrary execution, or mutable destination.

Every route produced here is an **unverified, inactive offline candidate**. This repository contains
no production addresses, deployment scripts, RPC configuration, relayer, activation mechanism, or
manifest that claims a route is active. See [Base compatibility](docs/base-compatibility.md),
[manifest and settlement facts](docs/manifest-and-settlement.md), and [security](SECURITY.md).
Factory identity, provenance, exact configuration, and the configured local CCTP domain remain
later admission requirements.

## Local checks

```sh
forge fmt --check
forge build
forge test -vvv
slither .
```

These commands compile and test local code only. They do not require an RPC endpoint.
