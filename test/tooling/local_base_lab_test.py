#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "bin/local-base-lab.py"
SPEC = importlib.util.spec_from_file_location("local_base_lab", MODULE_PATH)
assert SPEC and SPEC.loader
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)

WALLET = "0x" + "11" * 20
HOLDER = "0x" + "22" * 20
AUCTION = "0x" + "33" * 20
STRATEGY = "0x" + "44" * 20
FACTORY = "0x" + "55" * 20
TX_HASH = "0x" + "66" * 32


def word(value: int) -> str:
    return "0x" + f"{value:064x}"


class FakeRpc(lab.RpcClient):
    def __init__(
        self, url: str = "http://127.0.0.1:8545", chain_id: int = lab.LOCAL_CHAIN_ID
    ):
        super().__init__(url)
        self.chain_id = chain_id
        self.calls: list[tuple[str, list[object]]] = []
        self.results: dict[str, object] = {}

    def _request(self, method, params=()):
        self.calls.append((method, list(params)))
        if method == "eth_chainId":
            return hex(self.chain_id)
        result = self.results.get(method)
        return result() if callable(result) else result


class BoundaryTests(unittest.TestCase):
    def test_mutations_require_literal_loopback_and_chain_31337(self):
        for url in (
            "https://127.0.0.1:8545",
            "http://localhost:8545",
            "http://10.0.0.4:8545",
            "http://127.0.0.1:8545?x=1",
            "http://user:pass@127.0.0.1:8545",
        ):
            client = FakeRpc(url)
            with self.subTest(url=url), self.assertRaises(lab.LabError):
                client.mutate("anvil_mine", ["0x1"])
            self.assertFalse(any(method == "anvil_mine" for method, _ in client.calls))

        base = FakeRpc(chain_id=8453)
        with self.assertRaisesRegex(lab.LabError, "refusing mutation"):
            base.mutate("anvil_mine", ["0x1"])
        self.assertEqual(base.calls, [("eth_chainId", [])])

        local = FakeRpc()
        local.results["anvil_mine"] = True
        self.assertTrue(local.mutate("anvil_mine", ["0x1"]))
        self.assertEqual(
            local.calls[-2:], [("eth_chainId", []), ("anvil_mine", ["0x1"])]
        )

    def test_upstream_is_only_anvil_input_and_forge_children_are_scrubbed(self):
        secret = "https://provider.invalid/secret"
        command = lab.build_anvil_command(9123, secret, 123)
        self.assertEqual(command[command.index("--fork-url") + 1], secret)
        self.assertEqual(command[command.index("--host") + 1], "127.0.0.1")
        self.assertEqual(command[command.index("--chain-id") + 1], "31337")
        self.assertEqual(command[command.index("--fork-block-number") + 1], "123")
        with mock.patch.dict(os.environ, {lab.REGENT_BASE_RPC_ENV: secret}):
            anvil_environment = lab.child_environment()
            environment = lab.forge_environment({"EXTRA": "ok"})
        self.assertNotIn(lab.REGENT_BASE_RPC_ENV, anvil_environment)
        self.assertNotIn(lab.REGENT_BASE_RPC_ENV, environment)
        self.assertEqual(environment["FOUNDRY_OFFLINE"], "true")
        self.assertEqual(environment["EXTRA"], "ok")

    def test_missing_or_credentialed_upstream_is_refused(self):
        with self.assertRaises(lab.LabError):
            lab.validate_upstream_url("")
        with self.assertRaises(lab.LabError):
            lab.validate_upstream_url("https://user:pass@example.invalid")
        self.assertEqual(
            lab.validate_upstream_url("https://example.invalid/rpc"),
            "https://example.invalid/rpc",
        )

    def test_base_upstream_chain_passes_with_one_read_only_request(self):
        upstream = FakeRpc("https://provider.invalid/rpc", chain_id=8453)
        with mock.patch.object(lab, "RpcClient", return_value=upstream):
            lab.require_base_upstream(upstream.url)
        self.assertEqual(upstream.calls, [("eth_chainId", [])])

    def test_wrong_upstream_chain_stops_before_build_or_anvil(self):
        upstream = FakeRpc("https://provider.invalid/rpc", chain_id=1)
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.dict(
                    os.environ,
                    {lab.REGENT_BASE_RPC_ENV: upstream.url},
                    clear=False,
                ),
                mock.patch.object(lab, "repository_root", return_value=Path(directory)),
                mock.patch.object(lab, "RpcClient", return_value=upstream),
                mock.patch.object(lab, "compile_lab") as compile_lab,
                mock.patch.object(lab, "build_anvil_command") as build_anvil_command,
                mock.patch.object(lab, "start_anvil") as start_anvil,
                self.assertRaisesRegex(lab.LabError, "must be Base chain 8453"),
            ):
                lab.command_start(Namespace(fork_block=None))
        self.assertEqual(upstream.calls, [("eth_chainId", [])])
        compile_lab.assert_not_called()
        build_anvil_command.assert_not_called()
        start_anvil.assert_not_called()

    def test_recorded_process_must_match_anvil_host_port_and_chain(self):
        state = {"pid": 42, "rpc_url": "http://127.0.0.1:9123"}
        valid = [
            "/usr/local/bin/anvil",
            "--host",
            "127.0.0.1",
            "--port",
            "9123",
            "--chain-id",
            "31337",
            "--fork-url",
            "redacted",
        ]
        with mock.patch.object(lab, "process_command", return_value=valid):
            self.assertTrue(lab.recorded_anvil_matches(state))
        for changed in (
            ["python", "server.py"],
            ["anvil", "--host", "0.0.0.0", "--port", "9123", "--chain-id", "31337"],
            ["anvil", "--host", "127.0.0.1", "--port", "9124", "--chain-id", "31337"],
            ["anvil", "--host", "127.0.0.1", "--port", "9123", "--chain-id", "8453"],
        ):
            with mock.patch.object(lab, "process_command", return_value=changed):
                self.assertFalse(lab.recorded_anvil_matches(state))

    def test_stop_marks_replaced_process_stale_without_signalling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lab.atomic_write_json(
                root / lab.STATE_PATH,
                {
                    "status": "active",
                    "pid": 42,
                    "rpc_url": "http://127.0.0.1:9123",
                    "chain_id": lab.LOCAL_CHAIN_ID,
                },
            )
            with (
                mock.patch.object(lab, "repository_root", return_value=root),
                mock.patch.object(lab, "recorded_anvil_matches", return_value=False),
                mock.patch.object(os, "killpg") as killpg,
                self.assertRaisesRegex(lab.LabError, "marked stale"),
            ):
                lab.command_stop(Namespace())
            killpg.assert_not_called()
            self.assertEqual(lab.load_json(root / lab.STATE_PATH)["status"], "stale")


class DeploymentTests(unittest.TestCase):
    def graph_output(self) -> str:
        rows = []
        for index, label in enumerate(sorted(lab.GRAPH_LABELS), start=1):
            size = 64 if label == "hook_salt" else 40
            rows.append(f"REGENT_LOCAL_LAB_{label.upper()} 0x{index:0{size}x}")
        return "\n".join(rows)

    def test_deployment_requires_each_wrapper_label_once(self):
        output = self.graph_output()
        graph = lab.parse_deployment_graph(output)
        self.assertEqual(set(graph), lab.GRAPH_LABELS)
        with self.assertRaisesRegex(lab.LabError, "duplicate"):
            lab.parse_deployment_graph(output + "\n" + output.splitlines()[0])
        with self.assertRaisesRegex(lab.LabError, "complete"):
            lab.parse_deployment_graph("\n".join(output.splitlines()[:-1]))

    def test_unpause_uses_real_factory_call_and_always_stops_impersonation(self):
        client = FakeRpc()
        paused_reads = iter([word(1), word(0)])

        def result_for(method):
            if method == "eth_call":
                return next(paused_reads)
            if method == "eth_sendTransaction":
                return TX_HASH
            if method == "eth_getTransactionReceipt":
                return {"status": "0x1", "transactionHash": TX_HASH}
            return True

        client.results = {
            name: (lambda name=name: result_for(name))
            for name in (
                "eth_call",
                "anvil_setBalance",
                "anvil_impersonateAccount",
                "eth_sendTransaction",
                "eth_getTransactionReceipt",
                "anvil_stopImpersonatingAccount",
            )
        }
        lab.unpause_factory(client, FACTORY)
        methods = [method for method, _ in client.calls]
        self.assertIn("anvil_impersonateAccount", methods)
        self.assertIn("anvil_stopImpersonatingAccount", methods)
        transaction = next(
            params[0]
            for method, params in client.calls
            if method == "eth_sendTransaction"
        )
        self.assertEqual(transaction["from"], lab.GOVERNANCE_SAFE)
        self.assertEqual(transaction["to"], FACTORY)
        self.assertEqual(transaction["data"], lab.UNPAUSE_LAUNCHES)

    def test_impersonation_stops_on_failure(self):
        client = FakeRpc()
        client.results.update(
            {"anvil_impersonateAccount": True, "anvil_stopImpersonatingAccount": True}
        )
        with self.assertRaisesRegex(RuntimeError, "boom"):
            with lab.impersonated(client, HOLDER):
                raise RuntimeError("boom")
        self.assertEqual(
            [method for method, _ in client.calls if method.startswith("anvil_")],
            ["anvil_impersonateAccount", "anvil_stopImpersonatingAccount"],
        )

    def test_site_config_is_small_and_contains_no_upstream_or_private_key(self):
        graph = {
            label: ("0x" + "ab" * (32 if label == "hook_salt" else 20))
            for label in lab.GRAPH_LABELS
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lab.write_site_config(root, "http://127.0.0.1:9123", graph, {"factory": []})
            config = lab.load_json(root / lab.SITE_CONFIG_PATH)
        self.assertEqual(set(config), {"rpc_url", "chain_id", "addresses", "abis"})
        self.assertEqual(config["chain_id"], 31337)
        self.assertNotIn("hook_salt", config["addresses"])
        encoded = json.dumps(config).lower()
        self.assertNotIn("private", encoded)
        self.assertNotIn("upstream", encoded)
        self.assertEqual(config["addresses"]["regent"], lab.REGENT)
        self.assertEqual(config["addresses"]["permit2"], lab.PERMIT2)


class FundingTests(unittest.TestCase):
    def test_amount_and_transfer_calldata_are_exact(self):
        self.assertEqual(lab.parse_token_amount("1.25"), 1_250_000_000_000_000_000)
        with self.assertRaises(lab.LabError):
            lab.parse_token_amount("0")
        with self.assertRaises(lab.LabError):
            lab.parse_token_amount("0.0000000000000000001")
        data = lab.TRANSFER + lab.abi_address(WALLET) + lab.abi_uint(7)
        self.assertEqual(len(bytes.fromhex(data.removeprefix("0x"))), 68)
        self.assertTrue(data.startswith("0xa9059cbb"))

    def test_fund_rejects_using_holder_as_wallet(self):
        client = FakeRpc()
        with (
            mock.patch.object(lab, "local_client", return_value=({}, client)),
            self.assertRaisesRegex(lab.LabError, "must differ"),
        ):
            lab.command_fund(
                Namespace(wallet=HOLDER, holder=HOLDER, amount="1", wallet_eth="1")
            )

    def test_fund_uses_impersonated_real_transfer_and_stops(self):
        class FundingRpc(FakeRpc):
            def __init__(self):
                super().__init__()
                self.token_balances = {WALLET: 5, HOLDER: 100}

            def _request(self, method, params=()):
                self.calls.append((method, list(params)))
                if method == "eth_chainId":
                    return hex(lab.LOCAL_CHAIN_ID)
                if method == "eth_getBalance":
                    return "0x0"
                if method == "eth_call":
                    account = "0x" + params[0]["data"][-40:]
                    return word(self.token_balances[account])
                if method == "eth_sendTransaction":
                    data = params[0]["data"]
                    recipient = "0x" + data[34:74]
                    amount = int(data[74:], 16)
                    self.token_balances[HOLDER] -= amount
                    self.token_balances[recipient] += amount
                    return TX_HASH
                if method == "eth_getTransactionReceipt":
                    return {"status": "0x1", "transactionHash": TX_HASH}
                return True

        client = FundingRpc()
        with (
            mock.patch.object(lab, "local_client", return_value=({}, client)),
            mock.patch("builtins.print"),
        ):
            lab.command_fund(
                Namespace(
                    wallet=WALLET,
                    holder=HOLDER,
                    amount="0.000000000000000007",
                    wallet_eth="1",
                )
            )
        self.assertEqual(client.token_balances, {WALLET: 12, HOLDER: 93})
        methods = [method for method, _ in client.calls]
        self.assertIn("anvil_setBalance", methods)
        self.assertLess(
            methods.index("anvil_impersonateAccount"),
            methods.index("eth_sendTransaction"),
        )
        self.assertGreater(
            methods.index("anvil_stopImpersonatingAccount"),
            methods.index("eth_sendTransaction"),
        )


class TimingTests(unittest.TestCase):
    def test_real_timing_reads_include_strategy_migration(self):
        client = FakeRpc()
        values = {
            lab.START_BLOCK: word(100),
            lab.END_BLOCK: word(86_501),
            lab.CLAIM_BLOCK: word(86_565),
            lab.FUNDS_RECIPIENT: "0x" + "00" * 12 + STRATEGY[2:],
        }
        distribution_words = [0, 100, 86_501, 86_565, 86_629] + [0] * 13

        def eth_call():
            request = client.calls[-1][1][0]
            data = request["data"]
            if data.startswith(lab.DISTRIBUTION):
                return "0x" + "".join(f"{value:064x}" for value in distribution_words)
            return values[data]

        client.results["eth_call"] = eth_call
        timing = lab.auction_timing(client, AUCTION)
        self.assertEqual(
            timing,
            {
                "auction": AUCTION,
                "strategy": STRATEGY,
                "start": 100,
                "end": 86_501,
                "claim": 86_565,
                "migration": 86_629,
            },
        )
        self.assertEqual(lab.target_block(timing, "countdown"), 70)
        self.assertEqual(lab.target_block(timing, "migration"), 86_629)

    def test_mine_to_refuses_rewind_and_reaches_target(self):
        client = FakeRpc()
        heads = iter([hex(100), hex(120)])
        client.results["eth_blockNumber"] = lambda: next(heads)
        client.results["anvil_mine"] = True
        self.assertEqual(lab.mine_to(client, 120), 120)
        mine_params = next(
            params for method, params in client.calls if method == "anvil_mine"
        )
        self.assertEqual(mine_params, [hex(20)])

        past = FakeRpc()
        past.results["eth_blockNumber"] = hex(121)
        with self.assertRaisesRegex(lab.LabError, "already past"):
            lab.mine_to(past, 120)

    def test_pacing_uses_simple_elapsed_time_target(self):
        start = 1_000
        end = start + lab.AUCTION_BLOCKS
        self.assertEqual(lab.paced_target(start, end, 0, 1800), start)
        self.assertEqual(
            lab.paced_target(start, end, 900, 1800), start + lab.AUCTION_BLOCKS // 2
        )
        self.assertEqual(lab.paced_target(start, end, 1800, 1800), end)
        self.assertEqual(lab.paced_target(start, end, 3600, 1800), end)
        with self.assertRaises(lab.LabError):
            lab.paced_target(start, end, 1, 0)


class SurfaceTests(unittest.TestCase):
    def test_cli_exposes_only_the_practical_commands(self):
        parser = lab.build_parser()
        action = next(action for action in parser._actions if action.dest == "command")
        self.assertEqual(
            set(action.choices), {"start", "fund", "advance", "pace", "status", "stop"}
        )
        args = parser.parse_args(["pace", AUCTION])
        self.assertEqual(args.duration_seconds, 1800.0)
        args = parser.parse_args(["advance", AUCTION, "claim"])
        self.assertEqual(args.target, "claim")

    def test_overbuilt_audit_ceremony_is_removed(self):
        source = MODULE_PATH.read_text()
        for removed in (
            "approved_commit",
            "manifest_digest",
            "AckServer",
            "terminal_read_only",
            "SourceAuthorityGuard",
            "pending_transactions",
            "verify_terminal",
        ):
            self.assertNotIn(removed, source)

    def test_generated_paths_remain_under_the_ignored_lab_directory(self):
        for path in (lab.STATE_PATH, lab.SITE_CONFIG_PATH):
            self.assertTrue(path.is_relative_to(lab.GENERATED))

    def test_wrapper_and_profile_keep_local_guards(self):
        wrapper = (
            ROOT / "tools/local-base-lab/DeployLocalAutolaunchLab.s.sol"
        ).read_text()
        foundry = (ROOT / "foundry.toml").read_text()
        self.assertIn("block.chainid != LOCAL_CHAIN_ID", wrapper)
        self.assertIn("DeployAutolaunchV1", wrapper)
        self.assertIn("production.execute", wrapper)
        self.assertIn("[profile.local-base-lab]", foundry)
        self.assertIn("offline = true", foundry.split("[profile.local-base-lab]", 1)[1])
        self.assertIn("ffi = false", foundry.split("[profile.local-base-lab]", 1)[1])


if __name__ == "__main__":
    unittest.main()
