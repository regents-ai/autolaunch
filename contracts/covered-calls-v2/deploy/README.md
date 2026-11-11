# Deploying CoveredCallsV2 for AMZNc on Base

Status: **not deployed; waits for Sean.** Deploying a contract is Sean's decision, and nothing here
has been sent to Base. Everything below is prepared so that, on his go, he sends one transaction
and nothing else needs writing first.

## What it is

One transaction on Base (chain 8453), worth 0 ETH, to the deterministic deployer
`0x4e59b44847b379578588920cA78FbF26c0B4956C`. It creates `CoveredCallsV2` for AMZNc at:

**`0xee5B494B7974FeA38Add81a92eA3C794AdB8DDE6`**

The address comes only from the salt and the contract's code with its three arguments, so it is
the same whoever sends the transaction. The contract has no owner, admin, pause or upgrade: whoever
sends it gets no power over it.

| File | What it holds |
| --- | --- |
| `packet.json` | Everything: source commit, compiler settings, code hashes, each argument with where it came from, the salt, the predicted address, the transaction and the checks after it lands |
| `transaction-data.txt` | The transaction's data alone, to paste into a wallet |
| `build-packet.py` | Builds both files from this repository, offline (`uv run contracts/covered-calls-v2/deploy/build-packet.py`) |
| `rehearse.sh` | Runs the deploy script with `--broadcast` on a local copy of Base, checks it sent the packet's transaction byte for byte, and runs a whole life on what it leaves |
| `site-markets.json` | The markets file that switches the site on with this contract (below) |
| `../script/DeployCoveredCallsV2AMZNc.s.sol` | The deploy script: sends this packet's one transaction, with checks before and after |

| Item | Value |
| --- | --- |
| Salt | `0x791e83d46ce091730917e3ce8fec811133358eeb150b8ac039f4ab240eb9b4ae`, keccak256 of `autolaunch.covered-calls.v2.AMZNc` |
| Init code hash | `0xc8d65e4411ca8dd6a93c7c8121e6da717e7b4b71cd485f25a768e6903a1c0dc8` |
| Creation code hash | `0x745b26aecbfef3e02304c279dc5562cbad71e25ec5ced1a27e0d29b1d3f96f4c` |
| Runtime code hash | `0x96528893fe765ba369a54e616f68337d0a4d87689856f19baaca62c9621d51a8` |
| Source | `contracts/covered-calls-v2` at commit `755e7ce2cd79c38c55c2a435848b402a67baa5f8` (branch `al/cc-bids-site-1111`) |
| Compiler | solc 0.8.26+commit.8a97fa7a, Cancun, optimizer 200 runs, via-IR, no bytecode metadata |

## The arguments

The same three as CoveredCallsV1's, from the same records:

| Argument | Value | Source |
| --- | --- | --- |
| `stock_` | `0xb200000000000000000000d9192b6B456483C2E8` (AMZNc, 8 decimals) | `contracts/stocks-v2/deployments/base-mainnet/deployed-manifest.json`, the AMZNc admission |
| `usdc_` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC) | `contracts/stocks-v2/src/StocksBindings.sol`, `USDC` |
| `staking_` | `0xb027Dc261636E30Cbc0fE25b2F8e1ed273354AB5` (live REGENT staking) | `contracts/stocks-v2/src/StocksBindings.sol`, `LIVE_STAKING` |

`StocksBindings` is what the live Memestock fee hook (`0x385E40e1c07c215Ad1a7f5D8c2B878507dc520cc`)
was built with; its code on Base carries both the USDC and the staking address, and the staking
contract's own `usdc()` reads back Base USDC. CoveredCallsV1 on Base
(`0x0B2FE2810F9219bDd5e5e304DC8A1A4c84eA553E`) was built with the same three.

## Sending it

From your own terminal, with your own keystore, as the CoveredCallsV1 deploy went:

```bash
forge script script/DeployCoveredCallsV2AMZNc.s.sol --network base --rpc-url "$REGENT_BASE_RPC_URL" --account autolaunch-deployer --broadcast --slow
```

Run it from `contracts/covered-calls-v2`, with `../stocks-v2/lib` filled
(`contracts/stocks-v2/bootstrap-deps.py`). It needs **Foundry 1.8.4 or later**: the contract reads
AMZNc's decimals while it is created, forge runs that first on this machine, and Base stock tokens
only run in Foundry 1.8.4 and later with `--network base`.

`script/DeployCoveredCallsV2AMZNc.s.sol` sends exactly this packet's transaction:
`new CoveredCallsV2{salt}` in a broadcast goes through the deterministic deployer, so the data
forge sends is `transaction-data.txt`, byte for byte. Before sending, it requires Base (chain
8453), no code yet at the predicted address, and the packet's init code; after, the predicted
address, the packet's runtime code and the eight reads below. Any mismatch stops it before
anything is sent. It moves no funds and grants no roles, and the sender gains no power over the
contract. A second run, once the contract is there, stops with `AlreadyDeployed` and sends
nothing. Never add `--resume`: it re-sends a saved transaction without running these checks. The
checks after the send run in forge's own run-through before anything is sent; once the
transaction is mined, the checks under "After it lands" are run against Base itself.

The same transaction can also be sent without forge:

- **Any wallet that takes hex data:** a 0 ETH send to the deterministic deployer
  `0x4e59b44847b379578588920cA78FbF26c0B4956C`, with `transaction-data.txt` as its data and a gas
  limit of at least 1,900,000.
- **The Safe** `0x9fa152B0EAdbFe9A7c5C0a8e1D11784f22669a3e`, through its Transaction Builder: to
  the deterministic deployer, value 0, the data from `transaction-data.txt`, operation **Call**
  (never delegatecall), with at least 1,900,000 gas for the call.

Anyone may send this same transaction: if the address already holds the promised code, the
contract is deployed and nothing needs sending.

## Gas

1,736,901 used in the rehearsal; a copy of Base at block 56,034,461 estimated 1,761,536 (11
November 2026). `packet.json` asks for a limit of at least 1,900,000, and forge asks for up to
about 2.3M (its estimate with headroom; only what is used is paid). At Base's fees on 11 November
(a base fee of 0.005 gwei) it costs about 0.00001 ETH, a few cents.

## After it lands

`packet.json` → `post_deploy` lists what to check against Base itself, and each must match
exactly:

- the transaction's receipt has status 1;
- the code at the address hashes to `runtime_code_keccak`
  (`0x96528893fe765ba369a54e616f68337d0a4d87689856f19baaca62c9621d51a8`);
- `stock()`, `usdc()`, `staking()` are the three arguments, `unit()` is 100000000, `FEE_BPS()` is
  100 and `EXERCISE_WINDOW()` is 86400;
- `listingCount()` and `bidCount()` are 0, read at the block it landed in;
- the source verifies on Basescan with `basescan_verify`, run from `contracts/covered-calls-v2`
  with `ETHERSCAN_API_KEY` set and `../stocks-v2/lib` filled
  (`contracts/stocks-v2/bootstrap-deps.py`):

  ```bash
  forge verify-contract 0xee5B494B7974FeA38Add81a92eA3C794AdB8DDE6 src/CoveredCallsV2.sol:CoveredCallsV2 --chain base --compiler-version v0.8.26+commit.8a97fa7a --constructor-args 0x000000000000000000000000b200000000000000000000d9192b6b456483c2e8000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda02913000000000000000000000000b027dc261636e30cbc0fe25b2f8e1ed273354ab5 --watch
  ```

Then record the deployment in `deployed.json`, in the shape of
`contracts/covered-calls/deploy/deployed.json` (address, transaction, block, sender, gas, fee, the
checks run on Base, the source verification), and in the same commit point
`platform/test/autolaunch/covered_calls/deployment_test.exs` at `deployed.json` in place of
`packet.json`, as CoveredCallsV1's test read its record.

## Switching the site on

`site-markets.json` is the markets file the site reads (`Autolaunch.CoveredCalls.Deployment`):
Base, and for AMZNc its stock, this contract's predicted address and the AMZN price feed
`0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295` (the AMZNc admission's feed). The site test
`platform/test/autolaunch/covered_calls/deployment_test.exs` checks it reads as the site reads it
and names this packet's contract.

`platform/fly.toml` points the site at `platform/deployment/covered-calls.json`, which today names
CoveredCallsV1. Once the contract is on Base and the checks above match, the release that moves
the site to CoveredCallsV2 copies `site-markets.json` to `platform/deployment/covered-calls.json`;
no code path keeps reading V1. What to do about anything still unclaimed on V1 at that release is
in `../README.md` ("The cutover").

## Evidence (11 November 2026)

- The creation code is identical when built with Foundry 1.5.1 and 1.8.6, and is the code
  `bin/gate.sh` builds and tests (116 passed) at the packet's source commit. `build-packet.py`
  rebuilds `packet.json` and `transaction-data.txt` byte for byte.
- The standard JSON input `forge verify-contract` sends Basescan, compiled with plain solc
  0.8.26, gives the packet's creation code.
- `rehearse.sh` on a copy of Base at block 56,034,461: the deterministic deployer's code hash
  matches and the predicted address is empty; the deploy script sent the packet's transaction byte
  for byte from the Safe, and the contract landed at the predicted address with the promised code
  hash and reads. A whole life then ran on it with the real AMZNc, USDC and live staking: a listing
  filled, a bid sold into, raised, cancelled and refunded, both calls exercised in the window, the
  stock claimed and both strikes collected, 1% of each premium landing in staking and the contract
  left holding nothing.
- On a copy of Base at block 56,035,843 the packet's transaction, simulated from Sean's deployer
  address, from the Safe and from an unrelated address, creates the predicted address each time.
- Foundry's local copy of Base lacks the newer `effectiveAt()` read on stock tokens, so the
  rehearsal stands in its live value (0, nothing scheduled), as CoveredCallsV1's did.
