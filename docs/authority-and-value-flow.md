# Authority and Value-Flow Worksheet

This worksheet covers the offline EVM CCTP foundation only. It does not authorize deployment,
chain reads, address publication, activation, signing, or value movement.

## Call and authority table

| Artifact or step | Production caller | Initial owner/admin | Final owner/admin | Required transition | Can this caller perform it now? | Assets or allowances affected |
| --- | --- | --- | --- | --- | --- | --- |
| Construct `RevenueInboxFactoryV1` | Later founder-authorized deployer | None | None | None; every route parameter is fixed in construction | Yes in a later deployment transaction; not performed by this ticket | No assets or allowances |
| Deploy a route inbox | Any account or contract | None | None | Factory creates the inbox directly with its final bindings | Yes, atomically through `deploy(baseReceiver, baseSplitter)` | No assets or allowances |
| Repeat route deployment | Any account or contract | None | None | Return the existing exact-code, exact-binding inbox or fail closed | Yes, atomically through the same factory call | No assets or allowances |
| Receive source USDC | Any payer | None | None | Ordinary ERC-20 transfer to the deterministic inbox | Yes after a later admitted deployment | Source USDC ends at the inbox until swept |
| Set temporary CCTP allowance | The inbox during `sweep` | None | None | Exact allowance to the fixed TokenMessenger, then zero | Yes, in the same transaction | Source USDC allowance is `amount` only during the call |
| Initiate CCTP burn | Any `sweep` caller through the inbox | None | None | Fixed TokenMessenger pulls the bounded amount and emits the CCTP message | Yes after a later admitted deployment | The bounded source USDC amount is burned; no relayer custody |
| Complete destination mint | Any account accepted by CCTP | Circle-governed CCTP contracts, outside this repository | Same | No RevenueMesh role transition; destination caller is open | Yes after Circle attestation, outside this ticket | Native Base USDC is minted to the fixed Base receiver |
| Recognize Base revenue | Any caller of `PaymentReceiverV1.sweep` | Existing Autolaunch bindings | Same | No RevenueMesh role transition | Yes on an admitted receiver, outside this ticket | The receiver's complete bare Base USDC balance is routed to its bound splitter |

## Authority answers

- Factory construction is the only point at which source USDC, TokenMessenger V2, source domain,
  source namespace, source chain ID, minimum sweep, burn cap, and fee ceiling are selected.
- Route deployment is permissionless and accepts only the Base receiver and Base splitter. The
  created inbox has no owner, admin, pending owner, role, operator, or mutable configuration.
- The factory has no owner, role, pause, upgrade, arbitrary-call, rescue, or configuration setter.
- A sweep caller chooses only `maxFee`; the amount is derived from the inbox balance and immutable
  cap, and every destination and transport field is fixed.
- The caller can initiate a burn but cannot take custody, grant a role, change a recipient, or
  complete an authority transition.
- Base compatibility and provenance are later admission facts. This offline candidate cannot mark
  a pair active and performs no provider-backed Base read.
- A successful sweep finishes with the intended amount consumed and the TokenMessenger allowance
  at zero. Every token, messenger, under-consumption, or cleanup failure reverts the whole sweep,
  restoring the pre-call balance and allowance.
- `PaymentReceiverV1.sweep` routes the receiver's complete bare supported-token balance. Therefore
  one receiver sweep may aggregate multiple CCTP mints and donations; it is not evidence that one
  source burn was individually recognized.

## Final-state checklist

- [x] Every created route address must have code; deployment tests assert this.
- [x] Factory code identity, factory configuration, route identity, and inbox bindings are checked
      independently; repeat deployment fails closed on any mismatch.
- [x] No contract has an owner, admin, role holder, pending owner, or staged transition.
- [x] No deployer, factory, relayer, operator, or helper retains authority over an inbox.
- [x] A successful sweep consumes exactly the bounded amount and leaves zero allowance and no
      residual source USDC from that amount.
- [x] No intermediate RevenueMesh contract receives the Base mint; CCTP names the fixed Base
      receiver directly.
- [x] Each material external failure restores the pre-sweep balance and allowance.
- [x] Activation, address publication, live compatibility, CCTP completion, and Base recognition
      remain explicitly outside this offline ticket.
