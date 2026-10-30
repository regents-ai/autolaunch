"""A local copy of Base carrying the v2 Autolaunch contracts exactly as deployed, switched on, for
the agent journeys (scripts/agent-journeys.sh).

  python3 base_fork.py start   RUN CONTRACTS   copy Base at FORK_BLOCK onto a free loopback port (chain 31337)
  python3 base_fork.py prepare RUN CONTRACTS   stand-in stocks, then the switch-on steps from the Safe
  python3 base_fork.py configs RUN CONTRACTS   the site's two Base settings files, from the deployed manifests
  python3 base_fork.py covered-calls RUN CONTRACTS   AMZNc covered calls: the contract and its settings file
  python3 base_fork.py exposure RUN CONTRACTS   AMZNc Isolated Exposure to After-hours Stocks: a series and its settings file
  python3 base_fork.py stop    RUN CONTRACTS   stop the copy by its recorded pid

RUN holds the copy's pid, port and settings files; CONTRACTS is a contracts/ folder whose stocks-v2
package is built. Nothing here sends to a live chain. The only live reads are the fork's upstream
(REGENT_BASE_RPC_URL, reached by the foundry alias "base" so it never appears in a process list) and
each pool's stock balance, read through it.

On the copy only:
- Base stock tokens carry a one-byte 0xef runtime a local chain cannot run, so FixtureStockToken is
  installed at each admitted stock and each pool is minted the stock balance it holds on Base.
- For covered calls, LabStockToken (contracts/covered-calls/test/lab) is installed over AMZNc's
  stand-in, keeping its balances, because covered calls read the B20 multiplier and its scheduled
  change; then the CoveredCallsV1 deployed for AMZNc on Base (against Base's USDC and live REGENT
  staking) is placed at its own address with its code as Base holds it.
- For Isolated Exposure to After-hours Stocks, ExposureFactoryV1 and ChainlinkPrintOracleV2 (pinned to the AMZN
  feed's phase) are deployed and one AMZNc series created whose three prices (a close, an open and
  a close) fall in the copy's next few hours, so a journey can record and apply each one.
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
# Anvil's first development account, unlocked on the copy, deploys the Isolated Exposure to After-hours Stocks contracts.
DEPLOYER = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
AMZNC = "0xb200000000000000000000d9192b6b456483c2e8"
AMZN_FEED = "0x06a8e4b3abb3b7543d8396fb2b763d22820cb295"
USDC_HOLDER = "0xbbbbbbbbbb9cc5e90e3b3af64bdaf62c37eeffcb"  # Morpho Blue
AERODROME_FACTORY = "0x420dd381b31aef6683db6b902084cb0ffece40da"
# The approved terms of the first AMZNc series (platform/priv/exposure_terms), so the page's
# terms link opens a file the site serves.
EXPOSURE_TERMS = "0x5f67343b39277939aea7613c578fa3931b8b89da7a65eb36dd7217c81a5a2e8f"
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

    def covered_calls(self):
        """AMZNc's stand-in with the B20 reads covered calls make, the live CoveredCallsV1 for AMZNc
        at its Base address, and the site's covered-calls settings file."""
        package = self.contracts / "covered-calls"
        lab = json.loads((package / "out/LabStockToken.sol/LabStockToken.json").read_text())
        self.rpc("anvil_setCode", [AMZNC, lab["deployedBytecode"]["object"]])
        if self.call(AMZNC, "effectiveAt()(uint256)") != "0":
            sys.exit("the AMZNc lab stand-in does not answer effectiveAt()")
        # FORK_BLOCK is before the contract landed, so its code is read from Base as it stands and
        # placed at the same address. Its arguments are immutables in that code, and it starts with
        # no listings, as it did on Base.
        deployed = json.loads((package / "deploy/deployed.json").read_text())
        contract = deployed["address"].lower()
        code = self.cast("code", contract, rpc_url="base")
        keccak = subprocess.run(["cast", "keccak", code], capture_output=True, text=True, check=True).stdout.strip()
        if keccak != deployed["checks_on_base"]["runtime_code_keccak"]:
            sys.exit(f"the code at {contract} on Base is not the deployed CoveredCallsV1")
        self.rpc("anvil_setCode", [contract, code])
        stocks = json.loads((self.run / "base-memestock.json").read_text())["addresses"]
        reads = [self.call(contract, f"{name}()(address)").lower() for name in ("stock", "usdc", "staking")]
        if reads != [AMZNC, stocks["usdc"].lower(), stocks["live_staking"].lower()]:
            sys.exit(f"the deployed CoveredCallsV1 names {reads}, not this copy's AMZNc, USDC and staking")
        settings = {
            "chain_id": CHAIN_ID,
            "markets": [{"symbol": "AMZNc", "stock": AMZNC, "contract": contract, "feed": AMZN_FEED}],
        }
        (self.run / "covered-calls.json").write_text(json.dumps(settings, indent=1) + "\n")
        print(f"AMZNc covered calls at {contract}; {self.run / 'covered-calls.json'} written")

    def exposure(self):
        """One AMZNc Isolated Exposure to After-hours Stocks series, its factory and oracle, and the site's
        settings file. Its prices are a close ten minutes after the copy's time, an open two
        hours later and a close two hours after that."""
        package = self.contracts / "exposure"
        oracle = self.create(package, "src/ChainlinkPrintOracleV2.sol:ChainlinkPrintOracleV2", AMZN_FEED)
        factory = self.create(package, "src/ExposureFactoryV1.sol:ExposureFactoryV1", DEPLOYER)
        now = int(self.rpc("eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
        first = now + 600
        boundaries = f"[{first},{first + 7_200},{first + 14_400}]"
        feed_id = self.call(oracle, "feedId()(bytes32)")
        terms = (
            f"({AMZNC},{oracle},{feed_id},{EXPOSURE_TERMS},604800,40000000,{boundaries},"
            '"AMZNc After-hours journey","AMZNc-AH-J","AMZNc Market-hours journey","AMZNc-MH-J")'
        )
        signature = (
            "createSeries((address,address,bytes32,bytes32,uint64,uint256,uint64[],string,string,string,string))"
        )
        series = self.cast("call", "--from", DEPLOYER, factory, signature + "(address)", terms).lower()
        self.send_as(DEPLOYER, factory, signature, terms)
        if self.call(factory, "isSeries(address)(bool)", series) != "true":
            sys.exit("the factory did not list the journey's series")
        usdc = json.loads((self.run / "base-memestock.json").read_text())["addresses"]["usdc"]
        settings = {"chain_id": CHAIN_ID, "usdc": usdc, "pool_factory": AERODROME_FACTORY, "series": [series]}
        (self.run / "exposure.json").write_text(json.dumps(settings, indent=1) + "\n")
        print(f"AMZNc series {series} (prices at {boundaries}); {self.run / 'exposure.json'} written")

    def create(self, package, contract, *args):
        """Deploys `contract` from the unlocked deployer and returns its address."""
        created = subprocess.run(
            ["forge", "create", contract, "--rpc-url", self.url, "--from", DEPLOYER, "--unlocked",
             "--broadcast", "--constructor-args", *args],
            capture_output=True, text=True, cwd=package,
        )
        if created.returncode:
            sys.exit(created.stderr.strip()[:400])
        return next(line.split()[-1] for line in created.stdout.splitlines() if line.startswith("Deployed to:")).lower()

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
    {
        "start": fork.start,
        "prepare": fork.prepare,
        "configs": fork.configs,
        "covered-calls": fork.covered_calls,
        "exposure": fork.exposure,
        "stop": fork.stop,
    }[command]()
