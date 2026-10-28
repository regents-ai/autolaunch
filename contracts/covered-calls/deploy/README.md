# Deploying CoveredCallsV1 for AMZNc on Base

Status: **prepared, not sent.** Sending it is a contract deploy, a protected action that waits for
Sean's go naming it. Nothing here has been broadcast, and no key of ours has signed it.

## What it is

One transaction on Base (chain 8453), worth 0 ETH, to the deterministic deployer
`0x4e59b44847b379578588920cA78FbF26c0B4956C`. It creates `CoveredCallsV1` for AMZNc at:

**`0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E`**

The address comes only from the salt and the contract's code with its three arguments, so it is
the same whoever sends the transaction. The contract has no owner, admin, pause or upgrade: whoever
sends it gets no power over it.

| File | What it holds |
| --- | --- |
| `packet.json` | Everything: source commit, compiler settings, code hashes, each argument with where it came from, the salt, the predicted address, the transaction and the checks after it lands |
| `transaction-data.txt` | The transaction's data alone, to paste into a wallet |
| `build-packet.py` | Builds both files from this repository, offline (`uv run deploy/build-packet.py`) |
| `rehearse.sh` | Sends the exact transaction on a local copy of Base and runs a whole call's life on what it leaves |

## The arguments

| Argument | Value | Source |
| --- | --- | --- |
| `stock_` | `0xb200000000000000000000d9192b6B456483C2E8` (AMZNc, 8 decimals) | `contracts/stocks-v2/deployments/base-mainnet/deployed-manifest.json`, the AMZNc admission |
| `usdc_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC) | `contracts/stocks-v2/src/StocksBindings.sol`, `USDC` |
| `staking_` | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` (live REGENT staking) | `contracts/stocks-v2/src/StocksBindings.sol`, `LIVE_STAKING` |

`StocksBindings` is what the live Memestock fee hook (`0x385E40e1c07c215Ad1a7f5D8c2B878507dc520cc`)
was built with; its code on Base carries both the USDC and the staking address, and the staking
contract's own `usdc()` reads back Base USDC.

## Who signs

Recommended: **Sean's own wallet.** One signature, and the sender gains nothing. Paste
`transaction-data.txt` as the data of a 0 ETH send to the deterministic deployer, on Base, in any
wallet that takes hex data (in MetaMask, turn on "Show hex data" under Advanced settings).

The Safe `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` works too, through its Transaction Builder
(to the deployer, value 0, the same data). It gives the same address and adds only the Safe's
approvals.

Gas used in the rehearsal: 1,083,828.

## After it lands

`packet.json` → `post_deploy` lists what to check, and each must match exactly:

- the code at the address hashes to `runtime_code_keccak`;
- `stock()`, `usdc()`, `staking()` are the three arguments, `unit()` is 100000000, `FEE_BPS()` is
  100 and `EXERCISE_WINDOW()` is 86400;
- the source verifies on Basescan with `basescan_verify`, run from `contracts/covered-calls` with a
  Basescan key.

Then the site's covered-calls deployment record names the address, and covered calls open when the
switch is turned on, a separate release.

## Evidence (28 October 2026)

- The creation code is identical when built with Foundry 1.5.1 and 1.8.6, and is the code
  `bin/gate.sh` builds and tests (67 passed) at the packet's source commit.
- On Base: the deterministic deployer's code hash matches, read from two public endpoints, and the
  predicted address is empty.
- `rehearse.sh` on a copy of Base at block 53219530: the transaction succeeded from the Safe,
  the contract landed at the predicted address with the promised code hash and reads, and a whole
  life (list, buy, exercise, collect stock, collect strike) ran on it with the real AMZNc, USDC and
  live staking, the 1% fee landing in staking.
- Foundry's local copy of Base lacks the newer `effectiveAt()` read on stock tokens, so the
  rehearsal stands in its live value (0, nothing scheduled), as the fork suite does.
