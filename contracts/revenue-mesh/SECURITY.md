# Security

## Immutable route boundary

An inbox accepts only the exact source USDC fixed by its factory and calls only the factory's exact
TokenMessenger V2. The Base CCTP domain is 6, the minimum finality threshold is 2000, and the
destination caller is zero so completion is permissionless. The Base receiver and splitter are
constructor-bound and cannot be changed.

Anyone may call `sweep(maxFee)`. The inbox derives the amount as the lesser of its current source
USDC balance and the immutable per-message cap. It rejects a sub-minimum amount, a fee above the
immutable basis-point ceiling, and any fee equal to or greater than the burn amount. A successful
call provides only an exact temporary TokenMessenger allowance and finishes with zero allowance.
Under-consumption or any token, messenger, or cleanup failure reverts the complete call.

There is deliberately no owner, pause, proxy, upgrade, rescue, withdrawal, arbitrary call, or
destination escape hatch. Sending ETH, the wrong token, or an unsupported USDC representation may
strand it permanently. A failed or discontinued bridge can also strand the exact accepted USDC;
the route cannot redirect funds.

## Trust and activation boundary

CCTP is classified as `CCTP_ISSUER_NATIVE`; it depends on Circle's contracts and attestation
service. RevenueMesh does not take relayer custody, but it cannot remove the issuer trust model.

Code identity alone never establishes Base receiver compatibility. Later activation requires a
founder-authorized admission of the factory runtime identity, provenance, and exact immutable
configuration. The constructor proves the configured source chain ID equals the executing EVM
chain, but Circle's pinned `depositForBurn` interface exposes no local-domain getter. The configured
source CCTP domain must therefore be verified later against the admitted Circle messenger deployment
or exact CCTP message evidence, without assuming an unsupported generic messenger ABI.

Activation also requires a live Base read proving the frozen admitted receiver code hash, exact
receiver address, exact splitter binding, canonical Base USDC binding, zero referral basis points,
initialized state, and admitted Autolaunch provenance or equivalent frozen release evidence. A
canary must separately prove source burn, attested Base mint, and receiver-to-splitter recognition.
Until all later gates pass, every route remains unverified and inactive and its payment address must
not be published.

The Arbitrum One wrapper's fixed chain, domain, token, messenger, namespace, and burn-cap values are
offline configuration evidence only. Later admission must detect official-source changes and use a
new reviewed wrapper version rather than treating stale constants as active. This repository does
not perform a provider-backed check of those values.

No such live check, deployment, address publication, signing, burn, mint, or value movement is part
of this repository candidate.

## Static-analysis design notes

The inbox uses constructor-only storage instead of Solidity `immutable` fields so every route has
one uniform runtime code identity. The factory verifies that exact code hash and every constructor
binding before returning an existing CREATE2 route. There is no storage-writing function or
delegatecall surface.

The fee calculation intentionally uses quotient/remainder decomposition. It produces the exact
floor of `amount * feeBps / 10_000` without allowing the intermediate multiplication to overflow.
The manual sweep lock is set before token or messenger calls; a callback cannot enter another
sweep, and a revert restores the lock, balance, and allowance atomically. The success event is
necessarily emitted after the messenger and cleanup succeed.

The token helper uses checked low-level calls to support the ERC-20 convention that successful
methods may return either `true` or no data. CREATE2 requires one small assembly block because
Solidity has no high-level operation that exposes its salt semantics. These narrowly bounded uses
are covered by rollback, code-identity, and address-formula tests.
