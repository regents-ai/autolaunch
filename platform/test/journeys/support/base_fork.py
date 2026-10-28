"""A local copy of Base carrying the v2 Autolaunch contracts exactly as deployed, switched on, for
the agent journeys (scripts/agent-journeys.sh).

  python3 base_fork.py start   RUN CONTRACTS   copy Base at FORK_BLOCK onto a free loopback port (chain 31337)
  python3 base_fork.py prepare RUN CONTRACTS   stand-in stocks, then the switch-on steps from the Safe
  python3 base_fork.py configs RUN CONTRACTS   the site's two Base settings files, from the deployed manifests
  python3 base_fork.py stop    RUN CONTRACTS   stop the copy by its recorded pid

RUN holds the copy's pid, port and settings files; CONTRACTS is a contracts/ folder whose stocks-v2
package is built. Nothing here sends to a live chain. The only live reads are the fork's upstream
(REGENT_BASE_RPC_URL, reached by the foundry alias "base" so it never appears in a process list) and
each pool's stock balance, read through it.

On the copy only:
- Base stock tokens carry a one-byte 0xef runtime a local chain cannot run, so FixtureStockToken is
  installed at each admitted stock and each pool is minted the stock balance it holds on Base.
- Whatever of the switch-on Base does not already have is done from the impersonated Safe: each stock
  admitted with its route, the hook's executor named (Anvil's last development account), the v2
  Revstake factory and Memestock launchpad open, and the v1 pair paused.
"""

import json
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

CHAIN_ID = 31337
# The Base block every run copies, after the v2 deployments, so two runs start
# from the same chain. Moving it is a commit, and the evidence names it.
FORK_BLOCK = 53_180_000
SAFE = "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"
# Anvil's tenth development account; the journeys' people hold the second and third.
EXECUTOR = "0xa0ee7a142d267c1f36714e4a8f75612f20a79720"
V1_FACTORY = "0x635615ccef2ef24d0655fc2ebc47a14e005fef6e"
V1_LAUNCHPAD = "0x1d36a95112835f81b1b499a808e556020c64cac2"
USDC_HOLDER = "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"  # Morpho Blue
FAUCET = {
    "regent_holder": SAFE,
    "regent_amount": str(1_000 * 10**18),
    "stock_amount_units": "100",
    "usdc_holder": USDC_HOLDER,
    "usdc_amount": str(10_000 * 10**6),
}


class Fork:
    def __init__(self, run: Path, contracts: Path):
        self.run = run
        self.contracts = contracts
        self.alias_dir = contracts / "stocks-v2"
        port_file = run / "base-fork.port"
        self.url = f"http://127.0.0.1:{port_file.read_text().strip()}" if port_file.exists() else None

    def rpc(self, method, params=()):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
        request = urllib.request.Request(self.url, body, {"content-type": "application/json"})
        reply = json.loads(urllib.request.urlopen(request, timeout=120).read())
        if "error" in reply:
            sys.exit(f"{method}: {reply['error']}")
        return reply["result"]

    def cast(self, *args, rpc_url=None):
        result = subprocess.run(
            ["cast", *args, "--rpc-url", rpc_url or self.url], capture_output=True, text=True, cwd=self.alias_dir
        )
        if result.returncode:
            sys.exit(result.stderr.strip()[:400])
        return result.stdout.strip()

    def call(self, to, signature, *args):
        return self.cast("call", to, signature, *args)

    def send_as(self, sender, to, signature, *args):
        """Sends from any account on the copy (impersonated), waits, and requires success."""
        data = subprocess.run(
            ["cast", "calldata", signature, *args], capture_output=True, text=True, check=True
        ).stdout.strip()
        self.rpc("anvil_impersonateAccount", [sender])
        self.rpc("anvil_setBalance", [sender, hex(10**20)])
        tx = self.rpc("eth_sendTransaction", [{"from": sender, "to": to, "data": data, "gas": hex(3_000_000)}])
        receipt = None
        for _ in range(120):
            receipt = self.rpc("eth_getTransactionReceipt", [tx])
            if receipt:
                break
            time.sleep(0.25)
        self.rpc("anvil_stopImpersonatingAccount", [sender])
        if not receipt or int(receipt["status"], 16) != 1:
            sys.exit(f"{signature} from {sender} to {to} reverted")

    def manifest(self, package):
        return json.loads((self.contracts / package / "deployments/base-mainnet/deployed-manifest.json").read_text())

    @staticmethod
    def address_of(manifest, key):
        return next(c["address"] for c in manifest["contracts"] if c["contract_key"] == key).lower()

    def start(self):
        self.run.mkdir(parents=True, exist_ok=True)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        log = open(self.run / "base-fork.log", "w")
        process = subprocess.Popen(
            ["anvil", "--fork-url", "base", "--fork-block-number", str(FORK_BLOCK), "--host", "127.0.0.1",
             "--port", str(port), "--chain-id", str(CHAIN_ID), "--prune-history=64", "--silent"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, cwd=self.alias_dir,
        )
        (self.run / "base-fork.pid").write_text(str(process.pid))
        (self.run / "base-fork.port").write_text(str(port))
        self.url = f"http://127.0.0.1:{port}"
        for _ in range(120):
            try:
                if int(self.rpc("eth_chainId"), 16) == CHAIN_ID:
                    break
            except OSError:
                time.sleep(0.5)
        else:
            sys.exit("the copy of Base did not come up")
        print(f"copy of Base: chain {CHAIN_ID} on {self.url}, forked at Base block {FORK_BLOCK}")

    def prepare(self):
        fixture = self.alias_dir / "out/FixtureStockToken.sol/FixtureStockToken.json"
        runtime = json.loads(fixture.read_text())["deployedBytecode"]["object"]
        stocks = self.manifest("stocks-v2")
        for admission in stocks["admissions"]:
            stock, pool = admission["stock"], admission["pool"]
            live = int(
                self.cast("call", stock, "balanceOf(address)(uint256)", pool, "--block", str(FORK_BLOCK), rpc_url="base")
                .split()[0]
            )
            self.rpc("anvil_setCode", [stock, runtime])
            if self.call(stock, "symbol()(string)").strip('"') != admission["symbol"]:
                sys.exit(f"the stand-in at {stock} does not report {admission['symbol']}")
            self.send_as(SAFE, stock, "mint(address,uint256)", pool, str(live))
            print(f"{admission['symbol']:7} stand-in installed; its pool holds {live / 1e8:,.4f} as on Base at {FORK_BLOCK}")

        launchpad, hook = self.address_of(stocks, "launchpad"), self.address_of(stocks, "hook")
        factory = self.address_of(self.manifest("revstake-v2"), "factory")
        for admission in stocks["admissions"]:
            admitted = self.call(launchpad, "stockAdmission(address)(bool,uint8,address)", admission["stock"]).split()
            if admitted[0] != "true":
                self.send_as(SAFE, launchpad, "admitStock(address,address)", admission["stock"], admission["route"])
        print(f"{len(stocks['admissions'])} stocks admitted on the v2 launchpad {launchpad}")
        if self.call(hook, "executor()(address)").lower() != EXECUTOR:
            self.send_as(SAFE, hook, "setExecutor(address)", EXECUTOR)
        for target, paused in ((factory, False), (launchpad, False), (V1_FACTORY, True), (V1_LAUNCHPAD, True)):
            if (self.call(target, "launchesPaused()(bool)") == "true") != paused:
                self.send_as(SAFE, target, "pauseLaunches()" if paused else "unpauseLaunches()")
        print(f"v2 factory {factory} and launchpad {launchpad} open; v1 pair paused")

    def configs(self):
        """The two Base settings files, rendered by the ceremony tool from the deployed manifests."""
        launchpad = self.address_of(self.manifest("stocks-v2"), "launchpad")
        factory = self.address_of(self.manifest("revstake-v2"), "factory")
        for package, extra, name in (
            ("revstake-v2", [], "base-revstake.json"),
            ("stocks-v2", ["--agent-factory", factory], "base-memestock.json"),
        ):
            root = self.contracts / package
            subprocess.run(
                ["python3", "../stocks-v2/bin/ceremony.py", "site-config",
                 "--rpc-url", self.url, "--public-rpc-url", self.url, *extra],
                cwd=root, check=True, stdout=subprocess.DEVNULL,
            )
            document = json.loads((root / "reports/generated/deployment/site-config.json").read_text())
            document["chain_id"] = CHAIN_ID
            document.pop("start_blocks", None)  # the ledger stays off on the copy
            document.pop("public_rpc_url")  # a loopback chain is the browser's door too
            if package == "stocks-v2":
                document["faucet"] = FAUCET
                if document["addresses"]["launchpad"] != launchpad:
                    sys.exit("the rendered Memestock settings name another launchpad")
            (self.run / name).write_text(json.dumps(document, indent=1) + "\n")
            print(f"{self.run / name} written from {package}'s deployed manifest")

    def stop(self):
        """Stops the recorded Anvil, only while that pid is still an Anvil: after a
        restart the number may belong to anything else."""
        pid_file = self.run / "base-fork.pid"
        if not pid_file.exists():
            return
        pid = pid_file.read_text().strip()
        command = subprocess.run(["ps", "-p", pid, "-o", "comm="], capture_output=True, text=True).stdout.strip()
        if Path(command).name == "anvil":
            subprocess.run(["kill", pid], check=False)
            for _ in range(40):
                if subprocess.run(["kill", "-0", pid], capture_output=True).returncode != 0:
                    break
                time.sleep(0.25)
            print("copy of Base stopped")
        else:
            print(f"did not stop the copy of Base: pid {pid} is no longer the Anvil this script started")
        pid_file.unlink()
        (self.run / "base-fork.port").unlink(missing_ok=True)


if __name__ == "__main__":
    command, run, contracts = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    fork = Fork(run, contracts)
    {"start": fork.start, "prepare": fork.prepare, "configs": fork.configs, "stop": fork.stop}[command]()
