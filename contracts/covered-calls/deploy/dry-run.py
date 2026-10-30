# /// script
# requires-python = ">=3.11"
# dependencies = ["eth-abi==5.1.0", "eth-utils==5.1.0", "pycryptodome==3.21.0"]
# ///
"""A whole week of the deployed AMZNc CoveredCallsV1, simulated on Base mainnet as it is now.

Nothing is signed or sent: `eth_simulateV1` runs the calls on top of the latest Base block,
with the real AMZNc token (a B20 precompile no local fork fully runs), Base USDC and live
REGENT staking, then throws the result away. Three blocks:

1. Before expiry: a seller lists 2 AMZNc, a buyer buys 1.5, the seller stops selling the
   0.5 left and collects it; exercising this early is refused.
2. In the 24 hours after Friday's expiry: buying is refused; the buyer exercises 1 and the
   seller collects the strike.
3. After the window: exercising is refused; the buyer collects 1 AMZNc, the seller the 0.5
   not exercised, and the contract is left holding nothing of this listing.

Every token movement is checked to the unit, the 1% fee into staking included. The seller
and buyer are two addresses that hold AMZNc and USDC today; the simulation needs no key.

    uv run contracts/covered-calls/deploy/dry-run.py [BASE_RPC_URL]

Exits 0 when every step does exactly what the contract promises.
"""

import json
import sys
import urllib.request

from eth_abi import encode
from eth_utils import keccak

RPC = sys.argv[1] if len(sys.argv) > 1 else "https://mainnet.base.org"
DEPLOYED = json.load(open(__file__.rsplit("/", 1)[0] + "/deployed.json"))
CONTRACT = DEPLOYED["address"]
STOCK = DEPLOYED["checks_on_base"]["reads"]["stock()"]
USDC = DEPLOYED["checks_on_base"]["reads"]["usdc()"]
STAKING = DEPLOYED["checks_on_base"]["reads"]["staking()"]
SELLER = "0x532e0F46d1e528507FC9454d5847C231f23bDDf6"  # the AMZNc/USDC Aerodrome pool: holds AMZNc
BUYER = "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB"  # Aave's aBasUSDC: holds USDC

UNIT = 10**8
WEEK, EXPIRY_OFFSET, WINDOW = 7 * 86400, 86400 + 21 * 3600, 86400
TRANSFER = "0x" + keccak(text="Transfer(address,address,uint256)").hex()
NAMES = {CONTRACT: "contract", SELLER: "seller", BUYER: "buyer", STAKING: "staking", STOCK: "AMZNc", USDC: "USDC"}
NAMES = {address.lower(): name for address, name in NAMES.items()}


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(RPC, body, {"content-type": "application/json", "user-agent": "covered-calls-dry-run"})
    answer = json.load(urllib.request.urlopen(request, timeout=60))
    if "error" in answer:
        raise SystemExit(f"{method}: {answer['error']}")
    return answer["result"]


def call(sender, to, signature, *args):
    types = signature[signature.index("(") + 1 : -1].split(",") if args else []
    return {"from": sender, "to": to, "data": "0x" + (keccak(text=signature)[:4] + encode(types, list(args))).hex()}


def ceil_div(a, b):
    return -(-a // b)


latest = rpc("eth_getBlockByNumber", ["latest", False])
now = int(latest["timestamp"], 16)
expiry = now - now % WEEK + EXPIRY_OFFSET
expiry += WEEK if expiry <= now + 60 else 0
listing = int(rpc("eth_call", [call(SELLER, CONTRACT, "listingCount()"), latest["number"]]), 16) + 1

amount, bought, exercised = 2 * UNIT, 15 * UNIT // 10, UNIT
strike, premium = 250 * 10**6, 4 * 10**6
paid = ceil_div(bought * premium, UNIT)
fee = ceil_div(paid * 100, 10_000)
strike_paid = ceil_div(exercised * strike, UNIT)

# (what happens, the call, whether it should go through, the transfers it should make)
blocks = [
    (now + 2, [
        ("the seller approves 2 AMZNc", call(SELLER, STOCK, "approve(address,uint256)", CONTRACT, amount), True, []),
        ("the seller lists 2 AMZNc", call(SELLER, CONTRACT, "list(uint256,uint256,uint256,uint64)", amount, strike, premium, expiry), True,
         [("AMZNc", "seller", "contract", amount)]),
        ("exercising before expiry is refused", call(BUYER, CONTRACT, "exercise(uint256,uint256)", listing, 1), False, []),
        ("the buyer approves the premium", call(BUYER, USDC, "approve(address,uint256)", CONTRACT, paid), True, []),
        ("the buyer buys 1.5", call(BUYER, CONTRACT, "fill(uint256,uint256)", listing, bought), True,
         [("USDC", "buyer", "seller", paid - fee), ("USDC", "buyer", "contract", fee), ("USDC", "contract", "staking", fee)]),
        ("the seller stops selling the 0.5 left", call(SELLER, CONTRACT, "cancel(uint256)", listing), True, []),
        ("the seller collects the 0.5", call(SELLER, CONTRACT, "claim(uint256)", listing), True,
         [("AMZNc", "contract", "seller", amount - bought)]),
    ]),
    (expiry + 60, [
        ("buying after expiry is refused", call(BUYER, CONTRACT, "fill(uint256,uint256)", listing, 1), False, []),
        ("the buyer approves the strike", call(BUYER, USDC, "approve(address,uint256)", CONTRACT, strike_paid), True, []),
        ("the buyer exercises 1", call(BUYER, CONTRACT, "exercise(uint256,uint256)", listing, exercised), True,
         [("USDC", "buyer", "contract", strike_paid)]),
        ("the seller collects the strike", call(SELLER, CONTRACT, "collectStrike(uint256)", listing), True,
         [("USDC", "contract", "seller", strike_paid)]),
    ]),
    (expiry + WINDOW + 60, [
        ("exercising after the window is refused", call(BUYER, CONTRACT, "exercise(uint256,uint256)", listing, 1), False, []),
        ("the buyer collects 1 AMZNc", call(BUYER, CONTRACT, "claim(uint256)", listing), True,
         [("AMZNc", "contract", "buyer", exercised)]),
        ("the seller collects the 0.5 not exercised", call(SELLER, CONTRACT, "claim(uint256)", listing), True,
         [("AMZNc", "contract", "seller", bought - exercised)]),
        ("nothing is left to collect", call(SELLER, CONTRACT, "claim(uint256)", listing), False, []),
    ]),
]

results = rpc("eth_simulateV1", [{
    "blockStateCalls": [{"blockOverrides": {"time": hex(at)}, "calls": [c for _, c, _, _ in steps]} for at, steps in blocks],
    "validation": False,
    "traceTransfers": True,
}, latest["number"]])


def transfers(logs):
    for log in logs:
        token = NAMES.get(log["address"].lower())
        if log["topics"][0] == TRANSFER and token in ("AMZNc", "USDC"):
            sender, receiver = (NAMES.get("0x" + topic[-40:], "0x" + topic[-40:]) for topic in log["topics"][1:3])
            yield (token, sender, receiver, int(log["data"], 16))


print(f"Base block {int(latest['number'], 16)}: listing {listing} on {CONTRACT}, expiry {expiry}")
failures = 0
for (_, steps), result in zip(blocks, results):
    for (label, _, goes_through, expected), outcome in zip(steps, result["calls"]):
        went_through = outcome["status"] == "0x1"
        moved = list(transfers(outcome.get("logs", [])))
        right = went_through == goes_through and moved == expected
        failures += not right
        print(f"{'ok ' if right else 'BAD'} {label}" + ("" if went_through else " (refused)"))
        for token, sender, receiver, value in moved:
            print(f"      {value / (UNIT if token == 'AMZNc' else 10**6):g} {token}: {sender} -> {receiver}")
        if not right:
            print(f"      expected {'success' if goes_through else 'refusal'} with {expected}")

print(f"premium {paid / 10**6:g} USDC: {(paid - fee) / 10**6:g} to the seller, {fee / 10**6:g} (1%) to REGENT staking")
print("all as promised" if failures == 0 else f"{failures} step(s) not as promised")
sys.exit(0 if failures == 0 else 1)
