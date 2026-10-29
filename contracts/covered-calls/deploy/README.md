# Deploying CoveredCallsV1 for AMZNc on Base

Status: **deployed on Base** at [`0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E`](https://basescan.org/address/0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E), 29 October 2026,
transaction [`0xaa52f5ca…d6ba3a`](https://basescan.org/tx/0xaa52f5ca91f01533779514b78011ba20e65fd1f0bf6477a2d936aa57a4d6ba3a) in block 53,230,752, sent by Sean
from his own keystore (`0x9b2C414614aEE294202c1219520955EF3B596031`). Every check under "After it lands" passed against
Base itself, and the source is verified on Basescan (exact match) and Sourcify; `deployed.json` is the record. Covered calls
stay switched off on the site until a separate release turns them on.

## What it is

One transaction on Base (chain 8453), worth 0 ETH, to the deterministic deployer
`0x4e59b44847b379578588920cA78FbF26c0B4956C`. It creates `CoveredCallsV1` for AMZNc at:

**`0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E`**

The address comes only from the salt and the contract's code with its three arguments, so it is
the same whoever sends the transaction. The contract has no owner, admin, pause or upgrade: whoever
sends it gets no power over it.

| File | What it holds |
| --- | --- |
| `deployed.json` | The deployment: address, transaction, block, sender, gas, and the checks run against Base after it landed |
| `packet.json` | Everything: source commit, compiler settings, code hashes, each argument with where it came from, the salt, the predicted address, the transaction and the checks after it lands |
| `transaction-data.txt` | The transaction's data alone, to paste into a wallet |
| `build-packet.py` | Builds both files from this repository, offline (`uv run deploy/build-packet.py`) |
| `rehearse.sh` | Runs the deploy script with `--broadcast` on a local copy of Base, checks it sent the packet's transaction byte for byte, and runs a whole call's life on what it leaves |
| `../script/DeployCoveredCallsAMZNc.s.sol` | The deploy script: sends this packet's one transaction, with checks before and after |

## The arguments

| Argument | Value | Source |
| --- | --- | --- |
| `stock_` | `0xb200000000000000000000d9192b6B456483C2E8` (AMZNc, 8 decimals) | `contracts/stocks-v2/deployments/base-mainnet/deployed-manifest.json`, the AMZNc admission |
| `usdc_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC) | `contracts/stocks-v2/src/StocksBindings.sol`, `USDC` |
| `staking_` | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` (live REGENT staking) | `contracts/stocks-v2/src/StocksBindings.sol`, `LIVE_STAKING` |

`StocksBindings` is what the live Memestock fee hook (`0x385E40e1c07c215Ad1a7f5D8c2B878507dc520cc`)
was built with; its code on Base carries both the USDC and the staking address, and the staking
contract's own `usdc()` reads back Base USDC.

## Sending it

From your own terminal, with your own keystore, as the other deploys went:

```bash
forge script script/DeployCoveredCallsAMZNc.s.sol --network base --rpc-url "$REGENT_BASE_RPC_URL" --account autolaunch-deployer --broadcast --slow
```

Run it from `contracts/covered-calls`, with `../stocks-v2/lib` filled
(`contracts/stocks-v2/bootstrap-deps.py`). It needs **Foundry 1.8.4 or later**: the contract reads
AMZNc's decimals while it is created, forge runs that first on this machine, and Base stock tokens
only run in Foundry 1.8.4 and later with `--network base` (1.5.1 stops with `OpcodeNotFound`).

`script/DeployCoveredCallsAMZNc.s.sol` sends exactly this packet's transaction: `new CoveredCallsV1{salt}`
in a broadcast goes through the deterministic deployer, so the data forge sends is
`transaction-data.txt`, byte for byte. Before sending, it requires Base (chain 8453), no code yet
at the predicted address, and the packet's init code; after, the predicted address, the packet's
runtime code and the six reads. Any mismatch stops it before anything is sent. It moves no funds and
grants no roles, and the sender gains no power over the contract. A second run, once the contract
is there, stops with `AlreadyDeployed` and sends nothing. Never add `--resume`: it re-sends a saved
transaction without running these checks. The checks after the send run in forge's own run-through
before anything is sent; once the transaction is mined, the checks under "After it lands" are run
against Base itself.

Gas: 1,083,828 used in the rehearsal. forge asks for up to about 1.5M (its estimate with headroom),
which at Base's fees on 28 October (about 0.006 gwei) is about 0.0000065 ETH, a few cents.

The same transaction can also be sent without forge: `transaction-data.txt` as the data of a 0 ETH
send to the deterministic deployer, from any wallet that takes hex data, or from the Safe
`0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e` through its Transaction Builder (operation **Call**,
never delegatecall), with a gas limit of at least 1,200,000. Anyone may send this same transaction:
if the address already holds the promised code, the contract is deployed and nothing needs sending.

## After it lands

`packet.json` → `post_deploy` lists what to check, and each must match exactly:

- the transaction's receipt has status 1;
- the code at the address hashes to `runtime_code_keccak`;
- `stock()`, `usdc()`, `staking()` are the three arguments, `unit()` is 100000000, `FEE_BPS()` is
  100 and `EXERCISE_WINDOW()` is 86400;
- the source verifies on Basescan with `basescan_verify`, run from `contracts/covered-calls` with
  `ETHERSCAN_API_KEY` set and `../stocks-v2/lib` filled (`contracts/stocks-v2/bootstrap-deps.py`).

Then the site's covered-calls deployment record names the address, and covered calls open when the
switch is turned on, a separate release.

## A week on Base, without sending anything

`dry-run.py` runs a whole listing's life on the deployed contract on top of the latest Base block,
with the real AMZNc, USDC and REGENT staking, and throws it away (`eth_simulateV1`; no key, no
transaction). It lists, buys, stops selling, exercises in the window, collects the strike and both
sides' stock, checks three refusals at the window's edges, and checks every transfer to the unit,
the 1% fee into staking included. It is the one check that runs the real AMZNc's newer reads
(`effectiveAt()`), which no local fork runs yet.

```bash
uv run contracts/covered-calls/deploy/dry-run.py
```

It exits 0 when everything happens as promised. First run 29 October 2026 at Base block 53,256,332:
all 15 steps as promised; a 6 USDC premium paid 5.94 to the seller and 0.06 to staking.

## Evidence (28 October 2026)

- The creation code is identical when built with Foundry 1.5.1 and 1.8.6, and is the code
  `bin/gate.sh` builds and tests (67 passed) at the packet's source commit.
- On Base: the deterministic deployer's code hash matches, read from two public endpoints, and the
  predicted address is empty.
- The deploy script, simulated on live Base with no broadcast and no signer (Foundry 1.8.6),
  produces one transaction to the deterministic deployer, value 0, whose data is
  `transaction-data.txt` byte for byte, landing at the predicted address (29 October 2026).
- `rehearse.sh` on a copy of Base at block 53227062: the deploy script sent the packet's
  transaction byte for byte from the Safe, the contract landed at the predicted address with the promised code hash and reads, and a whole
  life (list, buy, exercise, collect stock, collect strike) ran on it with the real AMZNc, USDC and
  live staking, the 1% fee landing in staking.
- An independent review re-derived every argument from the repository's records and live Base,
  rebuilt the creation code three ways, recomputed the salt, address and runtime code, and found the
  packet correct; a dry run of the exact transaction on live Base (a read, nothing sent) returns the
  predicted address from any sender.
- Foundry's local copy of Base lacks the newer `effectiveAt()` read on stock tokens, so the
  rehearsal stands in its live value (0, nothing scheduled), as the fork suite does.
