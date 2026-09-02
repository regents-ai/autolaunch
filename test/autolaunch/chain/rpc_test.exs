defmodule Autolaunch.Chain.RpcTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.BaseRpcStub, as: Stub
  alias Autolaunch.Chain.Rpc

  @hash "0x" <> String.duplicate("ab", 32)
  @signer "0x1111111111111111111111111111111111111111"
  @target "0x2222222222222222222222222222222222222222"
  @data "0xabcdef"

  defmodule Client do
    def post(_url, options) do
      send(self(), {:wallet_http_client, options[:json]})
      {:ok, %{status: 200, body: %{"result" => "0x2105"}}}
    end
  end

  defmodule FailingClient do
    def post(_url, _options), do: {:error, :offline}
  end

  defmodule SequenceClient do
    def post(_url, _options) do
      [reply | rest] = Process.get(:rpc_replies)
      Process.put(:rpc_replies, rest)
      {:ok, %{status: 200, body: %{"result" => reply}}}
    end
  end

  defmodule RoutedClient do
    def post(_url, options) do
      method = options[:json][:method]
      result = Process.get({:rpc_result, method})
      {:ok, %{status: 200, body: %{"result" => result}}}
    end
  end

  defmodule LabClient do
    def post(url, options) do
      send(self(), {:lab_request, url, options[:json][:method]})
      {:ok, %{status: 200, body: %{"result" => "0x7a69"}}}
    end
  end

  setup do
    previous = Application.get_env(:autolaunch, :wallet_http_client)
    Application.put_env(:autolaunch, :wallet_http_client, Client)
    on_exit(fn -> restore(:wallet_http_client, previous) end)
  end

  test "ONE_EXACT_HASH_LANGUAGE: lowercase 0x and exactly 64 hexadecimal characters, nothing else" do
    hex = String.duplicate("ab", 32)
    truncated = "0x" <> String.duplicate("a", 63)

    for canonical <- [@hash, "0x" <> String.upcase(hex), "0x" <> String.duplicate("aB", 32)],
        do: assert(Rpc.valid_hash?(canonical), "#{inspect(canonical)} is canonical")

    for malformed <- [
          truncated <> "\n",
          "0x" <> hex <> "\n",
          truncated <> " ",
          truncated <> "\t",
          truncated,
          "0x" <> hex <> "a",
          "0x" <> String.duplicate("g", 64),
          "0X" <> hex,
          "",
          nil,
          :hash,
          String.to_charlist(@hash)
        ],
        do: refute(Rpc.valid_hash?(malformed), "#{inspect(malformed)} is not canonical")
  end

  test "uses the generic wallet client by default" do
    assert :ok = Rpc.verify_base_chain()
    assert_received {:wallet_http_client, %{method: "eth_chainId"}}
  end

  test "an explicit lab endpoint and chain never replace the default Base endpoint" do
    Application.put_env(:autolaunch, :lab_wallet_http_client, LabClient)
    on_exit(fn -> Application.delete_env(:autolaunch, :lab_wallet_http_client) end)

    assert :ok =
             Rpc.verify_chain(31_337,
               rpc_url: "http://127.0.0.1:49713",
               client_key: :lab_wallet_http_client
             )

    assert_received {:lab_request, "http://127.0.0.1:49713", "eth_chainId"}
    assert :ok = Rpc.verify_base_chain()
  end

  test "uses the generic wallet log scope by default" do
    Application.put_env(:autolaunch, :wallet_http_client, FailingClient)

    log =
      capture_log(fn -> assert {:error, :chain_unavailable} = Rpc.request("eth_chainId", []) end)

    assert log =~ "wallet chain read failed"
    refute log =~ "staking chain read failed"
  end

  test "requires successfully normalized signer and target before equality" do
    valid = transaction()
    zero = "0x" <> String.duplicate("0", 40)

    assert_status(:success, valid, @signer, @target, @data)
    mixed_case_signer = "0x" <> String.upcase(String.trim_leading(@signer, "0x"))
    assert_status(:success, %{valid | "from" => mixed_case_signer}, @signer, @target, @data)

    for {case_name, transaction, signer, target} <- [
          {:invalid_actual_signer, %{valid | "from" => "bad"}, @signer, @target},
          {:invalid_expected_signer, valid, "bad", @target},
          {:both_signers_invalid, %{valid | "from" => "bad"}, "also-bad", @target},
          {:zero_signers, %{valid | "from" => zero}, zero, @target},
          {:wrong_signer, %{valid | "from" => @target}, @signer, @target},
          {:wrong_target, %{valid | "to" => @signer}, @signer, @target},
          {:both_targets_invalid, %{valid | "to" => "bad"}, @signer, "also-bad"}
        ] do
      assert_error(case_name, :transaction_mismatch, transaction, signer, target, @data)
    end
  end

  test "rejects hash, calldata and value drift" do
    valid = transaction()

    assert_error(
      :wrong_hash,
      :transaction_mismatch,
      %{valid | "hash" => "0x" <> String.duplicate("cd", 32)},
      @signer,
      @target,
      @data
    )

    assert_error(
      :wrong_calldata,
      :transaction_mismatch,
      %{valid | "input" => "0xdead"},
      @signer,
      @target,
      @data
    )

    assert_error(
      :nonzero_value,
      :transaction_mismatch,
      %{valid | "value" => "0x1"},
      @signer,
      @target,
      @data
    )
  end

  test "distinguishes successful, reverted, pending, mismatched and invalid receipts" do
    assert_status(:success, transaction(), @signer, @target, @data)
    assert_status(:reverted, transaction(), @signer, @target, @data, "0x0")

    Process.put(:rpc_replies, ["0x2105", nil, transaction()])
    Application.put_env(:autolaunch, :wallet_http_client, SequenceClient)
    assert {:ok, :pending} = Rpc.submission_status(@hash, @signer, @target, @data)

    assert_receipt_error(
      %{
        "status" => "0x1",
        "blockNumber" => "0x1",
        "transactionHash" => "0x" <> String.duplicate("cd", 32)
      },
      :receipt_mismatch
    )

    assert_receipt_error(
      %{"status" => "0x2", "blockNumber" => "0x1", "transactionHash" => @hash},
      :invalid_receipt
    )
  end

  test "rejects a successful receipt when the injected provider is not Base" do
    receipt = %{"status" => "0x1", "blockNumber" => "0x1", "transactionHash" => @hash}

    for chain_result <- ["0x1", "not-hex", nil] do
      Process.put({:rpc_result, "eth_chainId"}, chain_result)
      Process.put({:rpc_result, "eth_getTransactionReceipt"}, receipt)
      Process.put({:rpc_result, "eth_getTransactionByHash"}, transaction())
      Application.put_env(:autolaunch, :wallet_http_client, RoutedClient)
      refute match?({:ok, :success}, Rpc.submission_status(@hash, @signer, @target, @data))
    end
  end

  # Canonical comes before status. A receipt above the safe head, and one whose
  # block is no longer the canonical block for its number, are both states this
  # transaction may still leave, whether it says success or revert right now.
  test "CANONICAL_BEFORE_STATUS: only a canonical safe receipt answers success or revert" do
    Stub.install(:wallet_http_client, fn _data, _state -> Stub.uint(0) end)
    Stub.put(%{transactions: %{@hash => transaction()}})
    safe = %{number: 0x20, hash: Stub.safe_hash()}
    moved = %{"0x10" => %{"number" => "0x10", "hash" => "0x" <> String.duplicate("99", 32)}}
    logs = [%{"address" => @target, "topics" => [], "data" => "0x"}]

    for {name, receipt, blocks, expected} <- [
          {"no receipt", nil, %{}, {:ok, :pending}},
          {"above-safe success", Stub.receipt(@hash, "0x21", logs), %{}, {:ok, :pending}},
          {"above-safe revert", Stub.receipt(@hash, "0x21", [], "0x0"), %{}, {:ok, :pending}},
          {"reorged success", Stub.receipt(@hash, "0x10", logs), moved, {:ok, :pending}},
          {"reorged revert", Stub.receipt(@hash, "0x10", [], "0x0"), moved, {:ok, :pending}},
          {"canonical success", Stub.receipt(@hash, "0x10", logs), %{}, {:ok, {:success, logs}}},
          {"canonical revert", Stub.receipt(@hash, "0x10", [], "0x0"), %{}, {:ok, :reverted}},
          {"unreadable canonical check", Stub.receipt(@hash, "0x10", logs),
           %{"0x10" => :unavailable}, {:error, :chain_unavailable}}
        ] do
      Stub.put(%{receipts: %{@hash => receipt}, blocks: blocks})

      assert Rpc.canonical_outcome(@hash, @signer, @target, @data, safe) == expected,
             "#{name} was classified wrongly"
    end
  end

  # A hash the wallet has just broadcast may not have reached this read RPC yet,
  # and a load-balanced provider may answer with its receipt before its
  # transaction. Identity that is merely unavailable waits on the same hash; only
  # a transaction this RPC did return, drifted from the envelope, is refused.
  test "PROPAGATION_LAG_IS_TRANSIENT: an unobserved transaction waits instead of failing" do
    Stub.install(:wallet_http_client, fn _data, _state -> Stub.uint(0) end)
    safe = %{number: 0x20, hash: Stub.safe_hash()}
    logs = [%{"address" => @target, "topics" => [], "data" => "0x"}]

    Stub.put(%{transactions: %{}, receipts: %{}})
    assert Rpc.submission_status(@hash, @signer, @target, @data) == {:ok, :pending}

    for {name, state, expected} <- [
          {"nothing observed", %{}, {:ok, :pending}},
          {"receipt ahead of the transaction",
           %{receipts: %{@hash => Stub.receipt(@hash, "0x10", logs)}},
           {:error, :transaction_missing}},
          {"drifted transaction",
           %{transactions: %{@hash => %{transaction() | "input" => "0xdead"}}},
           {:error, :transaction_mismatch}},
          {"caught up", %{transactions: %{@hash => transaction()}}, {:ok, {:success, logs}}}
        ] do
      Stub.put(state)

      assert Rpc.canonical_outcome(@hash, @signer, @target, @data, safe) == expected,
             "#{name} was classified wrongly"
    end
  end

  # The safe block already proved the chain identity, so an outcome judged
  # against it never asks for that identity again.
  test "CANONICAL_BEFORE_STATUS: the outcome read issues no second chain-id request" do
    Stub.install(:wallet_http_client, fn _data, _state -> Stub.uint(0) end)

    Stub.put(%{
      transactions: %{@hash => transaction()},
      receipts: %{@hash => Stub.receipt(@hash, "0x10", [])}
    })

    assert {:ok, {:success, []}} =
             Rpc.canonical_outcome(@hash, @signer, @target, @data, %{
               number: 0x20,
               hash: Stub.safe_hash()
             })

    refute_received {:rpc, "eth_chainId", _params}
  end

  defp transaction do
    %{"hash" => @hash, "from" => @signer, "to" => @target, "input" => @data, "value" => "0x0"}
  end

  defp assert_status(status, transaction, signer, target, data, receipt_status \\ "0x1") do
    receipt = %{"status" => receipt_status, "blockNumber" => "0x1", "transactionHash" => @hash}
    Process.put(:rpc_replies, ["0x2105", receipt, transaction])
    Application.put_env(:autolaunch, :wallet_http_client, SequenceClient)
    assert {:ok, ^status} = Rpc.submission_status(@hash, signer, target, data)
  end

  defp assert_error(case_name, reason, transaction, signer, target, data) do
    receipt = %{"status" => "0x1", "blockNumber" => "0x1", "transactionHash" => @hash}
    Process.put(:rpc_replies, ["0x2105", receipt, transaction])
    Application.put_env(:autolaunch, :wallet_http_client, SequenceClient)
    result = Rpc.submission_status(@hash, signer, target, data)
    assert result == {:error, reason}, "#{case_name} unexpectedly returned #{inspect(result)}"
  end

  defp assert_receipt_error(receipt, reason) do
    Process.put(:rpc_replies, ["0x2105", receipt, transaction()])
    Application.put_env(:autolaunch, :wallet_http_client, SequenceClient)
    assert {:error, ^reason} = Rpc.submission_status(@hash, @signer, @target, @data)
  end

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
