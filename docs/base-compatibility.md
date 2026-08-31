# Base Compatibility

The admitted Base profile is the pinned Autolaunch `PaymentReceiverV1`. Its permissionless
`sweep(address,bytes32)` reads the complete bare supported-token balance and routes it through the
receiver's stored splitter. That makes a direct native Base USDC mint compatible in principle and
removes the need for a Base landing adapter.

Compatibility still fails closed per instance. A later admission process must obtain current Base
facts and require all of the following at once:

- the exact expected receiver address;
- an initialized receiver;
- the frozen admitted receiver runtime code hash;
- `splitter()` equal to the supplied splitter;
- `usdc()` equal to canonical Base USDC;
- `referralBps()` equal to zero; and
- exact admitted factory provenance or equivalent frozen Autolaunch release evidence.

`BaseCompatibilityV1` evaluates those facts without treating code hash as sufficient. Its inputs
are observations, not proof that a chain read happened. This offline repository therefore never
turns a passing evaluation into activation and reports every candidate as `UNVERIFIED_INACTIVE`.
Provider-backed reads, production addresses, provenance admission, and activation are later
founder-authorized work.
