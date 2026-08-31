# Manifest and Settlement Facts

The factory exposes route facts suitable for a later manifest. They distinguish:

- bridge security class `CCTP_ISSUER_NATIVE`;
- settlement transport `CCTP_V2_STANDARD`;
- the exact accepted source token and TokenMessenger V2;
- source domain, Base domain 6, standard finality 2000, and permissionless completion;
- the immutable Base receiver and splitter;
- the factory-relative route ID and predicted payment address; and
- status `UNVERIFIED_INACTIVE`, with both compatibility and activation false.

No production address or active manifest is generated here. A later manifest must be tied to the
separately admitted factory and its immutable configuration; the same Base pair under another
factory or configuration is a different candidate.

## Receipt stages

Receipts must keep these stages distinct:

1. **Source received:** source USDC reached the source inbox.
2. **Burn initiated:** the source transaction called TokenMessenger V2 and produced the exact CCTP
   message evidence.
3. **Base minted:** an attested message minted the actual native Base USDC amount to the bound Base
   receiver.
4. **Receiver sweep observed:** `PaymentReceiverV1.sweep` routed its then-complete bare USDC balance
   to its bound splitter.
5. **Splitter recognition observed:** the splitter recorded the receiver sweep.

The pinned receiver sweep consumes the receiver's entire bare supported-token balance using one
caller-selected reference. Several CCTP mints and unrelated donations may therefore be aggregated
in one receiver sweep. A receiver or splitter event alone must never claim that one particular
source burn was individually recognized. Later receipts preserve the exact CCTP message and Base
mint evidence while representing receiver recognition as a possibly aggregated batch.
