#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import signal
import subprocess
import tempfile
import unittest
import urllib.request
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace
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
ORIGINAL_SAFE_RUNTIME = "0x60006000"
ADAPTER_RUNTIME = "0x60016001"
UPSTREAM_URL = "https://provider.invalid/v2/upstream-project-secret"


def word(value: int) -> str:
    return "0x" + f"{value:064x}"


def lab_graph() -> dict[str, str]:
    """One deployment graph whose seven addresses are all distinct."""
    return {
        label: "0x" + f"{index:0{64 if label == 'hook_salt' else 40}x}"
        for index, label in enumerate(sorted(lab.GRAPH_LABELS), start=1)
    }


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


class StartRpc(FakeRpc):
    """A local node whose per-address code readback can be emptied for one address."""

    def __init__(self, empty: str | None = None):
        super().__init__()
        self.empty = empty

    def _request(self, method, params=()):
        self.calls.append((method, list(params)))
        if method == "eth_chainId":
            return hex(self.chain_id)
        if method == "eth_getCode":
            return "0x" if params[0] == self.empty else ORIGINAL_SAFE_RUNTIME
        if method == "eth_accounts":
            return [WALLET]
        if method == "eth_blockNumber":
            return "0x64"
        return True


class AdminRpc(FakeRpc):
    def __init__(self, *, paused: bool = False):
        super().__init__()
        self.code = ORIGINAL_SAFE_RUNTIME
        self.adapter_admin = lab.FOUNDER_LOCAL_ADMIN
        self.adapter_factory = FACTORY
        self.fee = 25
        self.paused = paused
        self.regent_balance = 777
        self.snapshots: dict[str, tuple[str, int, bool, int]] = {}
        self.snapshot_counter = 0
        self.transaction_counter = 0
        self.send_failure_at: int | None = None
        self.unrelated_rejections = 0

    def _request(self, method, params=()):
        self.calls.append((method, list(params)))
        if method == "eth_chainId":
            return hex(self.chain_id)
        if method == "eth_getCode":
            return self.code
        if method == "evm_snapshot":
            self.snapshot_counter += 1
            snapshot_id = hex(self.snapshot_counter)
            self.snapshots[snapshot_id] = (
                self.code,
                self.fee,
                self.paused,
                self.regent_balance,
            )
            return snapshot_id
        if method == "evm_revert":
            snapshot_id = params[0]
            saved = self.snapshots.get(snapshot_id)
            if saved is None:
                return False
            self.code, self.fee, self.paused, self.regent_balance = saved
            return True
        if method == "anvil_setCode":
            self.code = params[1].lower()
            return True
        if method in {
            "anvil_setBalance",
            "anvil_impersonateAccount",
            "anvil_stopImpersonatingAccount",
        }:
            return True
        if method == "eth_sendTransaction":
            self.transaction_counter += 1
            if self.send_failure_at == self.transaction_counter:
                raise lab.LabError("injected transaction failure")
            transaction = params[0]
            if transaction["from"] != lab.FOUNDER_LOCAL_ADMIN:
                raise lab.LabError("unexpected transaction sender")
            data = transaction["data"]
            if data.startswith(lab.SET_LAUNCH_FEE):
                self.fee = int(data[len(lab.SET_LAUNCH_FEE) :], 16)
            elif data == lab.PAUSE_LAUNCHES:
                if self.paused:
                    raise lab.LabError("already paused")
                self.paused = True
            elif data == lab.UNPAUSE_LAUNCHES:
                if not self.paused:
                    raise lab.LabError("not paused")
                self.paused = False
            else:
                raise lab.LabError("unexpected admin selector")
            return "0x" + f"{self.transaction_counter:064x}"
        if method == "eth_getTransactionReceipt":
            return {"status": "0x1", "transactionHash": params[0]}
        if method == "eth_call":
            request = params[0]
            target = request.get("to")
            data = request.get("data", "0x")
            if target == lab.GOVERNANCE_SAFE:
                if "from" in request:
                    if request["from"] == lab.UNRELATED_ADMIN:
                        self.unrelated_rejections += 1
                        raise lab.RpcError(
                            "eth_call",
                            "execution reverted",
                            lab.NOT_ADMIN + lab.abi_address(lab.UNRELATED_ADMIN),
                        )
                    raise lab.LabError("unexpected eth_call sender")
                if data == lab.ADMIN:
                    return "0x" + lab.abi_address(self.adapter_admin)
                if data == lab.FACTORY:
                    return "0x" + lab.abi_address(self.adapter_factory)
            if target == FACTORY:
                if data == lab.LAUNCH_FEE:
                    return word(self.fee)
                if data == lab.LAUNCHES_PAUSED:
                    return word(int(self.paused))
            if target == lab.REGENT:
                return word(self.regent_balance)
            raise lab.LabError("unexpected eth_call")
        return True


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

    def test_malformed_local_rpc_ports_fail_as_lab_errors(self):
        for url in ("http://127.0.0.1:99999", "http://127.0.0.1:abc"):
            with (
                self.subTest(url=url),
                self.assertRaisesRegex(lab.LabError, "local RPC URL must"),
            ):
                lab.validate_loopback_rpc_url(url)

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

    def test_every_command_refuses_beside_a_repository_root_dotenv(self):
        commands = (
            ["start"],
            ["status"],
            ["stop"],
            ["admin", lab.FOUNDER_LOCAL_ADMIN],
            ["advance", AUCTION, "start"],
            ["pace", AUCTION],
            ["fund", WALLET, "--holder", HOLDER, "--amount", "1"],
        )
        for name in lab.DOTENV_NAMES:
            for command in commands:
                with (
                    self.subTest(dotenv=name, command=command[0]),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    root = Path(directory)
                    (root / name).write_text(
                        f"{lab.REGENT_BASE_RPC_ENV}={UPSTREAM_URL}\n"
                    )
                    stderr = io.StringIO()
                    with (
                        mock.patch.object(lab, "repository_root", return_value=root),
                        mock.patch.object(subprocess, "run") as run,
                        mock.patch.object(subprocess, "Popen") as popen,
                        mock.patch.object(urllib.request, "urlopen") as urlopen,
                        contextlib.redirect_stderr(stderr),
                    ):
                        self.assertEqual(lab.main(command), 1)
                    self.assertIn(name, stderr.getvalue())
                    self.assertNotIn(UPSTREAM_URL, stderr.getvalue())
                    run.assert_not_called()
                    popen.assert_not_called()
                    urlopen.assert_not_called()

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
    @contextlib.contextmanager
    def start_context(self, root: Path, client: StartRpc, graph: dict[str, str]):
        with (
            mock.patch.dict(os.environ, {lab.REGENT_BASE_RPC_ENV: UPSTREAM_URL}),
            mock.patch.object(lab, "repository_root", return_value=root),
            mock.patch.object(lab, "require_base_upstream"),
            mock.patch.object(lab, "compile_lab"),
            mock.patch.object(lab, "load_abis", return_value={}),
            mock.patch.object(lab, "reserve_port", return_value=8545),
            mock.patch.object(
                lab, "start_anvil", return_value=SimpleNamespace(pid=999)
            ),
            mock.patch.object(lab, "terminate_process"),
            mock.patch.object(lab, "RpcClient", return_value=client),
            mock.patch.object(lab, "deploy_graph", return_value=graph),
            mock.patch.object(lab, "unpause_factory"),
            mock.patch.object(
                lab, "keccak_code", return_value=lab.PINNED_SAFE_RUNTIME_HASH
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            yield

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

    def test_site_config_is_a_closed_field_set_with_no_upstream_value(self):
        graph = lab_graph()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.dict(os.environ, {lab.REGENT_BASE_RPC_ENV: UPSTREAM_URL}):
                lab.write_site_config(
                    root, "http://127.0.0.1:9123", graph, {"factory": []}
                )
            written = (root / lab.SITE_CONFIG_PATH).read_text()
            config = lab.load_json(root / lab.SITE_CONFIG_PATH)
        self.assertEqual(set(config), {"rpc_url", "chain_id", "addresses", "abis"})
        self.assertEqual(
            set(config["addresses"]),
            (lab.GRAPH_LABELS - {"hook_salt"})
            | {
                "regent",
                "permit2",
                "cca_factory",
                "pool_manager",
                "position_manager",
                "governance_safe",
            },
        )
        self.assertEqual(config["chain_id"], 31337)
        self.assertEqual(config["rpc_url"], "http://127.0.0.1:9123")
        self.assertEqual(config["abis"], {"factory": []})
        self.assertEqual(config["addresses"]["regent"], lab.REGENT)
        self.assertEqual(config["addresses"]["permit2"], lab.PERMIT2)
        for leaked in (
            UPSTREAM_URL,
            "provider.invalid",
            "upstream-project-secret",
            lab.REGENT_BASE_RPC_ENV,
        ):
            self.assertNotIn(leaked, written)
        for value in (
            [config["rpc_url"], str(config["chain_id"])]
            + list(config["addresses"].values())
            + [json.dumps(config["abis"])]
        ):
            self.assertNotIn("provider.invalid", value)
            self.assertNotIn("private", value.lower())

    def test_start_captures_the_pinned_safe_runtime_in_generated_state(self):
        graph = lab_graph()
        client = StartRpc()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.start_context(root, client, graph):
                lab.command_start(Namespace(fork_block=None))
            state = lab.load_json(root / lab.STATE_PATH)
            self.assertEqual(
                state["governance_safe_original_runtime"], ORIGINAL_SAFE_RUNTIME
            )
            config = lab.load_json(root / lab.SITE_CONFIG_PATH)
            self.assertNotIn("local_admin", state)
            self.assertNotIn("local_admin", config)
            self.assertEqual(set(state["addresses"]), lab.GRAPH_LABELS - {"hook_salt"})
        read = [params[0] for method, params in client.calls if method == "eth_getCode"]
        for address in state["addresses"].values():
            self.assertIn(address, read)

    def test_start_writes_nothing_when_a_deployed_address_has_no_code(self):
        graph = lab_graph()
        for label in sorted(lab.GRAPH_LABELS - {"hook_salt"}):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                client = StartRpc(empty=graph[label])
                with (
                    self.start_context(root, client, graph),
                    self.assertRaisesRegex(
                        lab.LabError, f"{label} has no runtime code"
                    ),
                ):
                    lab.command_start(Namespace(fork_block=None))
                self.assertFalse((root / lab.STATE_PATH).exists())
                self.assertFalse((root / lab.SITE_CONFIG_PATH).exists())

    def test_termination_during_start_stops_anvil_and_reports_one_clean_line(self):
        class SignalledStartRpc(StartRpc):
            """Deliver SIGTERM after the deployment lands but before state.json exists."""

            def __init__(self):
                super().__init__()
                self.delivered = False

            def _request(self, method, params=()):
                if method == "eth_blockNumber" and not self.delivered:
                    self.delivered = True
                    os.kill(os.getpid(), signal.SIGTERM)
                return super()._request(method, params)

        graph = lab_graph()
        outer_handler = signal.getsignal(signal.SIGTERM)
        for entry in ("command_start", "main"):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                client = SignalledStartRpc()
                stderr = io.StringIO()
                with (
                    self.start_context(root, client, graph),
                    mock.patch.object(lab, "terminate_process") as terminate,
                    contextlib.redirect_stderr(stderr),
                ):
                    if entry == "main":
                        self.assertEqual(lab.main(["start"]), 1)
                    else:
                        with self.assertRaisesRegex(lab.TerminationSignal, "SIGTERM"):
                            lab.command_start(Namespace(fork_block=None))
                self.assertTrue(client.delivered)
                self.assertIs(signal.getsignal(signal.SIGTERM), outer_handler)
                terminate.assert_called_once()
                self.assertEqual(terminate.call_args.args[0].pid, 999)
                self.assertFalse((root / lab.STATE_PATH).exists())
                self.assertFalse((root / lab.SITE_CONFIG_PATH).exists())
                self.assertEqual(
                    stderr.getvalue(),
                    "local Base lab failed: received SIGTERM\n"
                    if entry == "main"
                    else "",
                )

    def test_adapter_runtime_uses_exactly_two_encoded_constructor_addresses(self):
        client = FakeRpc()
        client.results["eth_call"] = ADAPTER_RUNTIME
        with (
            mock.patch.object(lab, "compile_lab"),
            mock.patch.object(lab, "load_adapter_initcode", return_value="0x6000"),
        ):
            runtime = lab.adapter_runtime(
                ROOT, client, lab.FOUNDER_LOCAL_ADMIN, FACTORY
            )
        self.assertEqual(runtime, ADAPTER_RUNTIME)
        request = next(
            params[0] for method, params in client.calls if method == "eth_call"
        )
        self.assertNotIn("to", request)
        self.assertEqual(len(bytes.fromhex(request["data"].removeprefix("0x"))), 2 + 64)


class AdminTests(unittest.TestCase):
    def write_documents(self, root: Path, *, baseline: bool = True):
        state = {
            "status": "active",
            "pid": 42,
            "rpc_url": "http://127.0.0.1:8545",
            "chain_id": lab.LOCAL_CHAIN_ID,
            "addresses": {"factory": FACTORY},
        }
        if baseline:
            state["governance_safe_original_runtime"] = ORIGINAL_SAFE_RUNTIME
        config = {
            "rpc_url": state["rpc_url"],
            "chain_id": lab.LOCAL_CHAIN_ID,
            "addresses": {
                "factory": FACTORY,
                "governance_safe": lab.GOVERNANCE_SAFE,
            },
            "abis": {},
        }
        lab.atomic_write_json(root / lab.STATE_PATH, state)
        lab.atomic_write_json(root / lab.SITE_CONFIG_PATH, config)
        return state, config

    @contextlib.contextmanager
    def admin_context(self, root: Path, state, client: AdminRpc):
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(lab, "repository_root", return_value=root)
            )
            stack.enter_context(
                mock.patch.object(lab, "local_client", return_value=(state, client))
            )
            stack.enter_context(
                mock.patch.object(lab, "adapter_runtime", return_value=ADAPTER_RUNTIME)
            )
            stack.enter_context(
                mock.patch.object(
                    lab, "keccak_code", return_value=lab.PINNED_SAFE_RUNTIME_HASH
                )
            )
            stack.enter_context(mock.patch("builtins.print"))
            yield

    def test_first_install_proves_all_calls_and_preserves_state_and_custody(self):
        for paused in (False, True):
            with (
                self.subTest(paused=paused),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                state, _config = self.write_documents(root)
                client = AdminRpc(paused=paused)
                with self.admin_context(root, state, client):
                    lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))

                saved_state = lab.load_json(root / lab.STATE_PATH)
                saved_config = lab.load_json(root / lab.SITE_CONFIG_PATH)
                self.assertEqual(client.code, ADAPTER_RUNTIME)
                self.assertEqual((client.fee, client.paused), (25, paused))
                self.assertEqual(client.regent_balance, 777)
                self.assertEqual(client.unrelated_rejections, 1)
                self.assertEqual(
                    saved_state["governance_safe_original_runtime"],
                    ORIGINAL_SAFE_RUNTIME,
                )
                self.assertEqual(saved_state["local_admin"], lab.FOUNDER_LOCAL_ADMIN)
                self.assertEqual(saved_config["local_admin"], lab.FOUNDER_LOCAL_ADMIN)
                sent = [
                    params[0]["data"]
                    for method, params in client.calls
                    if method == "eth_sendTransaction"
                ]
                self.assertTrue(
                    any(data.startswith(lab.SET_LAUNCH_FEE) for data in sent)
                )
                self.assertIn(lab.PAUSE_LAUNCHES, sent)
                self.assertIn(lab.UNPAUSE_LAUNCHES, sent)

    def test_pre_amendment_state_seeds_only_the_pinned_clean_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state, _config = self.write_documents(root, baseline=False)
            client = AdminRpc()
            with self.admin_context(root, state, client):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            self.assertEqual(
                lab.load_json(root / lab.STATE_PATH)[
                    "governance_safe_original_runtime"
                ],
                ORIGINAL_SAFE_RUNTIME,
            )

    def test_proof_failure_restores_code_factory_json_and_balance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state, _config = self.write_documents(root)
            state_bytes = (root / lab.STATE_PATH).read_bytes()
            config_bytes = (root / lab.SITE_CONFIG_PATH).read_bytes()
            client = AdminRpc()
            client.send_failure_at = 2
            with (
                self.admin_context(root, state, client),
                self.assertRaisesRegex(lab.LabError, "injected"),
            ):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            self.assertEqual(client.code, ORIGINAL_SAFE_RUNTIME)
            self.assertEqual((client.fee, client.paused), (25, False))
            self.assertEqual(client.regent_balance, 777)
            self.assertEqual((root / lab.STATE_PATH).read_bytes(), state_bytes)
            self.assertEqual((root / lab.SITE_CONFIG_PATH).read_bytes(), config_bytes)

    def test_install_verification_failure_rolls_back_before_proof(self):
        class IgnoredCodeWriteRpc(AdminRpc):
            def _request(self, method, params=()):
                if method == "anvil_setCode":
                    self.calls.append((method, list(params)))
                    return True
                return super()._request(method, params)

        for client, message in (
            (IgnoredCodeWriteRpc(), "exact requested runtime"),
            (AdminRpc(), "factory binding"),
        ):
            with (
                self.subTest(message=message),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                state, _config = self.write_documents(root)
                if message == "factory binding":
                    client.adapter_factory = WALLET
                state_bytes = (root / lab.STATE_PATH).read_bytes()
                config_bytes = (root / lab.SITE_CONFIG_PATH).read_bytes()
                with (
                    self.admin_context(root, state, client),
                    self.assertRaisesRegex(lab.LabError, message),
                ):
                    lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
                self.assertEqual(client.code, ORIGINAL_SAFE_RUNTIME)
                self.assertEqual((client.fee, client.paused), (25, False))
                self.assertEqual(client.regent_balance, 777)
                self.assertEqual((root / lab.STATE_PATH).read_bytes(), state_bytes)
                self.assertEqual(
                    (root / lab.SITE_CONFIG_PATH).read_bytes(), config_bytes
                )

    def test_persistence_failure_restores_exact_prior_documents_and_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state, _config = self.write_documents(root)
            state_bytes = (root / lab.STATE_PATH).read_bytes()
            config_bytes = (root / lab.SITE_CONFIG_PATH).read_bytes()
            client = AdminRpc()
            real_write = lab.atomic_write_json
            writes = 0

            def fail_second_write(path, document):
                nonlocal writes
                writes += 1
                if writes == 2:
                    raise OSError("injected persistence failure")
                real_write(path, document)

            with (
                self.admin_context(root, state, client),
                mock.patch.object(
                    lab, "atomic_write_json", side_effect=fail_second_write
                ),
                self.assertRaisesRegex(lab.LabError, "rolled back.*persistence"),
            ):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            self.assertEqual(client.code, ORIGINAL_SAFE_RUNTIME)
            self.assertEqual((client.fee, client.paused), (25, False))
            self.assertEqual(client.regent_balance, 777)
            self.assertEqual((root / lab.STATE_PATH).read_bytes(), state_bytes)
            self.assertEqual((root / lab.SITE_CONFIG_PATH).read_bytes(), config_bytes)

    def test_termination_signal_rolls_back_chain_and_both_documents(self):
        class TerminatedRpc(AdminRpc):
            """Deliver a termination signal after the adapter code is installed."""

            def __init__(self, number: int):
                super().__init__()
                self.number = number
                self.delivered = False

            def _request(self, method, params=()):
                if (
                    method == "evm_snapshot"
                    and self.code == ADAPTER_RUNTIME
                    and not self.delivered
                ):
                    self.delivered = True
                    # The installed handler raises before the next bytecode runs.
                    os.kill(os.getpid(), self.number)
                return super()._request(method, params)

        for number in (signal.SIGTERM, signal.SIGHUP):
            with (
                self.subTest(signal=signal.Signals(number).name),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                state, _config = self.write_documents(root)
                state_bytes = (root / lab.STATE_PATH).read_bytes()
                config_bytes = (root / lab.SITE_CONFIG_PATH).read_bytes()
                client = TerminatedRpc(number)
                outer_handler = signal.getsignal(number)
                with (
                    self.admin_context(root, state, client),
                    self.assertRaisesRegex(
                        lab.LabError,
                        f"rolled back.*{signal.Signals(number).name}",
                    ),
                ):
                    lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
                self.assertTrue(client.delivered)
                self.assertIs(signal.getsignal(number), outer_handler)
                self.assertEqual(client.code, ORIGINAL_SAFE_RUNTIME)
                self.assertEqual((client.fee, client.paused), (25, False))
                self.assertEqual(client.regent_balance, 777)
                self.assertEqual((root / lab.STATE_PATH).read_bytes(), state_bytes)
                self.assertEqual(
                    (root / lab.SITE_CONFIG_PATH).read_bytes(), config_bytes
                )

    def test_a_second_signal_cannot_interrupt_the_admin_rollback(self):
        class DoubleSignalRpc(AdminRpc):
            """Terminate mid-install, then again once the rollback is under way."""

            def __init__(self, second_at: str | None):
                super().__init__()
                self.second_at = second_at
                self.first = False
                self.second = False

            def _request(self, method, params=()):
                if (
                    method == "evm_snapshot"
                    and self.code == ADAPTER_RUNTIME
                    and not self.first
                ):
                    self.first = True
                    os.kill(os.getpid(), signal.SIGTERM)
                if method == self.second_at and not self.second:
                    self.second = True
                    os.kill(os.getpid(), signal.SIGHUP)
                return super()._request(method, params)

        for step in ("chain revert", "JSON restore"):
            with self.subTest(step=step), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                state, _config = self.write_documents(root)
                state_bytes = (root / lab.STATE_PATH).read_bytes()
                config_bytes = (root / lab.SITE_CONFIG_PATH).read_bytes()
                client = DoubleSignalRpc(
                    "evm_revert" if step == "chain revert" else None
                )
                real_restore = lab.restore_optional_bytes
                restores: list[Path] = []

                def restore(path, content):
                    restores.append(path)
                    if step == "JSON restore" and len(restores) == 1:
                        os.kill(os.getpid(), signal.SIGHUP)
                    real_restore(path, content)

                stderr = io.StringIO()
                with (
                    mock.patch.object(lab, "repository_root", return_value=root),
                    mock.patch.object(
                        lab, "local_client", return_value=(state, client)
                    ),
                    mock.patch.object(
                        lab, "adapter_runtime", return_value=ADAPTER_RUNTIME
                    ),
                    mock.patch.object(
                        lab, "keccak_code", return_value=lab.PINNED_SAFE_RUNTIME_HASH
                    ),
                    mock.patch.object(
                        lab, "restore_optional_bytes", side_effect=restore
                    ),
                    contextlib.redirect_stdout(io.StringIO()),
                    contextlib.redirect_stderr(stderr),
                ):
                    self.assertEqual(lab.main(["admin", lab.FOUNDER_LOCAL_ADMIN]), 1)

                self.assertTrue(client.first)
                self.assertEqual(client.second, step == "chain revert")
                self.assertEqual(len(restores), 2)
                self.assertIn("SIGTERM", stderr.getvalue())
                self.assertNotIn("SIGHUP", stderr.getvalue())
                self.assertEqual(client.code, ORIGINAL_SAFE_RUNTIME)
                self.assertEqual((client.fee, client.paused), (25, False))
                self.assertEqual(client.regent_balance, 777)
                self.assertEqual((root / lab.STATE_PATH).read_bytes(), state_bytes)
                self.assertEqual(
                    (root / lab.SITE_CONFIG_PATH).read_bytes(), config_bytes
                )
                self.assertFalse(
                    {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
                    & signal.pthread_sigmask(signal.SIG_BLOCK, [])
                )

    def test_matching_repeat_is_a_verified_no_op(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state, _config = self.write_documents(root)
            client = AdminRpc()
            with self.admin_context(root, state, client):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            state_bytes = (root / lab.STATE_PATH).read_bytes()
            config_bytes = (root / lab.SITE_CONFIG_PATH).read_bytes()
            repeat_state = lab.load_json(root / lab.STATE_PATH)
            call_count = len(client.calls)
            with self.admin_context(root, repeat_state, client):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            repeat_methods = [method for method, _ in client.calls[call_count:]]
            self.assertFalse(
                any(
                    method
                    in {
                        "anvil_setCode",
                        "eth_sendTransaction",
                        "evm_snapshot",
                        "evm_revert",
                    }
                    for method in repeat_methods
                )
            )
            self.assertEqual((root / lab.STATE_PATH).read_bytes(), state_bytes)
            self.assertEqual((root / lab.SITE_CONFIG_PATH).read_bytes(), config_bytes)
            self.assertEqual((client.fee, client.paused), (25, False))

    def test_runtime_or_binding_mismatch_refuses_before_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state, config = self.write_documents(root)
            client = AdminRpc()
            client.code = "0xdeadbeef"
            with (
                self.admin_context(root, state, client),
                self.assertRaisesRegex(lab.LabError, "unrecognized runtime"),
            ):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            self.assertFalse(
                any(method == "evm_snapshot" for method, _ in client.calls)
            )

            client = AdminRpc()
            client.code = ADAPTER_RUNTIME
            client.adapter_factory = WALLET
            state["local_admin"] = lab.FOUNDER_LOCAL_ADMIN
            config["local_admin"] = lab.FOUNDER_LOCAL_ADMIN
            lab.atomic_write_json(root / lab.STATE_PATH, state)
            lab.atomic_write_json(root / lab.SITE_CONFIG_PATH, config)
            with (
                self.admin_context(root, state, client),
                self.assertRaisesRegex(lab.LabError, "factory binding"),
            ):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            self.assertFalse(
                any(method == "evm_snapshot" for method, _ in client.calls)
            )

    def test_wrong_admin_is_refused_before_lab_or_rpc_access(self):
        with (
            mock.patch.object(lab, "local_client") as local_client,
            self.assertRaisesRegex(lab.LabError, "founder-authorized"),
        ):
            lab.command_admin(Namespace(admin=WALLET))
        local_client.assert_not_called()

    def test_admin_inherits_active_lab_loopback_and_chain_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state, _config = self.write_documents(root)
            mainnet = FakeRpc(chain_id=lab.BASE_CHAIN_ID)
            with (
                mock.patch.object(lab, "repository_root", return_value=root),
                mock.patch.object(lab, "recorded_anvil_matches", return_value=True),
                mock.patch.object(lab, "RpcClient", return_value=mainnet),
                self.assertRaisesRegex(lab.LabError, "expected local chain"),
            ):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))
            self.assertEqual(mainnet.calls, [("eth_chainId", [])])

            state["rpc_url"] = "http://10.0.0.1:8545"
            lab.atomic_write_json(root / lab.STATE_PATH, state)
            with (
                mock.patch.object(lab, "repository_root", return_value=root),
                self.assertRaisesRegex(lab.LabError, "literal loopback"),
            ):
                lab.command_admin(Namespace(admin=lab.FOUNDER_LOCAL_ADMIN))

    def test_status_displays_the_installed_local_admin(self):
        client = FakeRpc()
        client.results["eth_blockNumber"] = "0x64"
        state = {
            "rpc_url": client.url,
            "addresses": {"factory": FACTORY},
            "local_admin": lab.FOUNDER_LOCAL_ADMIN,
        }
        with (
            mock.patch.object(lab, "local_client", return_value=(state, client)),
            mock.patch("builtins.print") as output,
        ):
            lab.command_status(Namespace(auction=None))
        displayed = json.loads(output.call_args.args[0])
        self.assertEqual(displayed["local_admin"], lab.FOUNDER_LOCAL_ADMIN)

    def test_pinned_safe_runtime_is_a_required_baseline(self):
        with mock.patch.object(
            lab, "keccak_code", return_value=lab.PINNED_SAFE_RUNTIME_HASH
        ):
            self.assertEqual(
                lab.require_clean_safe_runtime(ROOT, ORIGINAL_SAFE_RUNTIME),
                ORIGINAL_SAFE_RUNTIME,
            )
        with (
            mock.patch.object(lab, "keccak_code", return_value="0x" + "00" * 32),
            self.assertRaisesRegex(lab.LabError, "pinned clean baseline"),
        ):
            lab.require_clean_safe_runtime(ROOT, ORIGINAL_SAFE_RUNTIME)


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


class ArtifactDerivationTests(unittest.TestCase):
    """Every pinned selector and ABI offset must still come out of the compiled sources."""

    ADAPTER = "LocalFactoryGovernance"
    FUNCTION_SELECTORS = {
        "TRANSFER": (lab.ABI_TARGETS["token"], "transfer(address,uint256)"),
        "BALANCE_OF": (lab.ABI_TARGETS["token"], "balanceOf(address)"),
        "ADMIN": (ADAPTER, "admin()"),
        "FACTORY": (ADAPTER, "factory()"),
        "SET_LAUNCH_FEE": (ADAPTER, "setLaunchFee(uint256)"),
        "PAUSE_LAUNCHES": (ADAPTER, "pauseLaunches()"),
        "UNPAUSE_LAUNCHES": (ADAPTER, "unpauseLaunches()"),
        "LAUNCH_FEE": (lab.ABI_TARGETS["factory"], "launchFee()"),
        "LAUNCHES_PAUSED": (lab.ABI_TARGETS["factory"], "launchesPaused()"),
        "START_BLOCK": (lab.ABI_TARGETS["auction"], "startBlock()"),
        "END_BLOCK": (lab.ABI_TARGETS["auction"], "endBlock()"),
        "CLAIM_BLOCK": (lab.ABI_TARGETS["auction"], "claimBlock()"),
        "FUNDS_RECIPIENT": (lab.ABI_TARGETS["auction"], "fundsRecipient()"),
        "DISTRIBUTION": (lab.ABI_TARGETS["strategy"], "distribution(address)"),
    }
    ERROR_SELECTORS = {"NOT_ADMIN": (ADAPTER, "NotAdmin(address)")}
    STATIC_ABI_TYPES = {
        "uint8",
        "uint64",
        "uint128",
        "uint160",
        "uint256",
        "address",
        "bytes32",
    }
    _inspected: dict[tuple[str, str], object] = {}

    @classmethod
    def inspect(cls, contract: str, field: str):
        key = (contract, field)
        if key not in cls._inspected:
            completed = subprocess.run(
                ["forge", "inspect", contract, field, "--json"],
                cwd=ROOT,
                env=lab.forge_environment(),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=True,
            )
            cls._inspected[key] = json.loads(completed.stdout)
        return cls._inspected[key]

    @staticmethod
    def selector_shaped_constants() -> set[str]:
        """Every module-level selector-shaped string, whatever case name or value uses."""
        return {
            name
            for name, value in vars(lab).items()
            if isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]{8}", value)
        }

    def test_every_pinned_selector_constant_is_derived_from_an_artifact(self):
        derived = set(self.FUNCTION_SELECTORS) | set(self.ERROR_SELECTORS)
        self.assertEqual(self.selector_shaped_constants(), derived)
        self.assertEqual(len(derived), 15)
        for name, value in (("EXTRA_SEL", "0xA9059CBB"), ("ExtraSel", "0xa9059cbb")):
            with (
                self.subTest(injected=name),
                mock.patch.object(lab, name, value, create=True),
            ):
                self.assertEqual(self.selector_shaped_constants() - derived, {name})

    def test_function_selectors_match_the_compiled_method_identifiers(self):
        for name, (contract, signature) in sorted(self.FUNCTION_SELECTORS.items()):
            identifiers = self.inspect(contract, "methodIdentifiers")
            with self.subTest(constant=name):
                self.assertIn(signature, identifiers)
                self.assertEqual(getattr(lab, name), "0x" + identifiers[signature])

    def test_error_selectors_match_the_compiled_error_identifiers(self):
        for name, (contract, signature) in sorted(self.ERROR_SELECTORS.items()):
            errors = self.inspect(contract, "errors")
            with self.subTest(constant=name):
                self.assertIn(signature, errors)
                self.assertEqual(getattr(lab, name), "0x" + errors[signature])

    def test_adapter_stays_well_inside_the_code_size_limits_with_a_fixed_surface(self):
        artifact_path = (
            ROOT
            / lab.GENERATED
            / "foundry-out/LocalFactoryGovernance.sol/LocalFactoryGovernance.json"
        )
        if not artifact_path.exists():
            lab.compile_lab(ROOT)
        artifact = lab.load_json(artifact_path)
        runtime = bytes.fromhex(
            artifact["deployedBytecode"]["object"].removeprefix("0x")
        )
        initcode = bytes.fromhex(artifact["bytecode"]["object"].removeprefix("0x"))
        self.assertLessEqual(len(runtime), 24_576 - 1_000)
        self.assertLessEqual(len(initcode) + 64, 49_152 - 1_000)

        expected = {
            signature: getattr(lab, name).removeprefix("0x")
            for name, (contract, signature) in self.FUNCTION_SELECTORS.items()
            if contract == self.ADAPTER
        }
        self.assertEqual(len(expected), 5)
        self.assertEqual(artifact["methodIdentifiers"], expected)

    def test_distribution_migration_offset_comes_from_the_compiled_abi(self):
        abi = self.inspect(lab.ABI_TARGETS["strategy"], "abi")
        entry = next(
            item
            for item in abi
            if item.get("type") == "function" and item.get("name") == "distribution"
        )
        components = entry["outputs"][0]["components"]
        self.assertEqual(
            {component["type"] for component in components} - self.STATIC_ABI_TYPES,
            set(),
        )
        self.assertEqual(len(components), 18)
        index = [component["name"] for component in components].index("migrationBlock")
        self.assertEqual(index, 4)

        migration = 86_629
        words = [0] * len(components)
        words[index] = migration
        client = FakeRpc()
        values = {
            lab.START_BLOCK: word(100),
            lab.END_BLOCK: word(86_501),
            lab.CLAIM_BLOCK: word(86_565),
            lab.FUNDS_RECIPIENT: "0x" + "00" * 12 + STRATEGY[2:],
        }

        def eth_call():
            data = client.calls[-1][1][0]["data"]
            if data.startswith(lab.DISTRIBUTION):
                return "0x" + "".join(f"{value:064x}" for value in words)
            return values[data]

        client.results["eth_call"] = eth_call
        self.assertEqual(lab.auction_timing(client, AUCTION)["migration"], migration)


class SurfaceTests(unittest.TestCase):
    def test_cli_exposes_only_the_practical_commands(self):
        parser = lab.build_parser()
        action = next(action for action in parser._actions if action.dest == "command")
        self.assertEqual(
            set(action.choices),
            {"start", "admin", "fund", "advance", "pace", "status", "stop"},
        )
        args = parser.parse_args(["admin", lab.FOUNDER_LOCAL_ADMIN])
        self.assertEqual(args.admin, lab.FOUNDER_LOCAL_ADMIN)
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

    def test_adapter_surface_is_fixed_and_has_no_custody_or_upgrade_path(self):
        source = (ROOT / "tools/local-base-lab/LocalFactoryGovernance.sol").read_text()
        for required in (
            "address public immutable admin",
            "address public immutable factory",
            "function setLaunchFee(uint256 newFee)",
            "function pauseLaunches()",
            "function unpauseLaunches()",
        ):
            self.assertIn(required, source)
        for forbidden in (
            "delegatecall",
            "selfdestruct",
            "function execute",
            "function transfer",
            "function recover",
            "receive()",
            "fallback()",
            "payable",
        ):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
