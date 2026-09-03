defmodule Autolaunch.TreasuryChainClientTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Actors.System
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: Client
  alias Autolaunch.{TreasuryChainClient, TreasurySecurity}

  @safe_hash "0x" <> String.duplicate("aa", 32)
  @address "0x9999999999999999999999999999999999999999"
  @singleton "0x41675c099f32341bf84bfc5382af534df5c7461a"
  @fallback "0xfd0732dc9e303f09fcef3a7388ad10a83459ec99"
  @zero "0x0000000000000000000000000000000000000000"
  @sentinel "0x0000000000000000000000000000000000000001"
  @owners [
    "0x1111111111111111111111111111111111111111",
    "0x2222222222222222222222222222222222222222",
    "0x3333333333333333333333333333333333333333"
  ]
  @guard_slot "0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c7"
  @fallback_slot "0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d4"
  @proxy_runtime "0x608060405273ffffffffffffffffffffffffffffffffffffffff600054167fa619486e0000000000000000000000000000000000000000000000000000000060003514156050578060005260206000f35b3660008037600080366000845af43d6000803e60008114156070573d6000fd5b3d6000f3fea264697066735822122003d1488ee65e08fa41e58e888a9865554c535f2c77126a82cb4c0f917f31441364736f6c63430007060033"
  @evidence_hashes Enum.map(["11", "22", "33"], &("0x" <> String.duplicate(&1, 32)))
  @receipt_hashes Enum.map(["b1", "b2", "b3"], &("0x" <> String.duplicate(&1, 32)))
  @singleton_runtime_gzip "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"

  defmodule HttpClient do
    def post(_url, options) do
      request = options[:json]
      send(self(), {:treasury_rpc, request.method, request.params})

      case rpc_response(request.method, request.params) do
        {:error, reason} ->
          {:ok, %{status: 200, body: %{"error" => %{"message" => to_string(reason)}}}}

        result ->
          {:ok, %{status: 200, body: %{"result" => result}}}
      end
    end

    defp rpc_response("eth_chainId", _params), do: "0x2105"

    defp rpc_response("eth_getBlockByNumber", ["safe", false]),
      do: %{"number" => "0x30", "hash" => state().safe_hash}

    defp rpc_response("eth_getBlockByNumber", [number, false]),
      do:
        Map.get(state().headers, number, %{
          "number" => Map.get(state().header_numbers, number, number),
          "hash" => block_hash(number)
        })

    defp rpc_response("eth_getCode", [address, block]) do
      same_block!(block)
      Map.get(state().codes, String.downcase(address), "0x")
    end

    defp rpc_response("eth_getStorageAt", [address, slot, block]) do
      same_block!(block)
      true = String.downcase(address) == state().address
      Map.fetch!(state().storage, slot)
    end

    defp rpc_response("eth_call", [%{to: address, data: data}, block]) do
      same_block!(block)
      true = String.downcase(address) == state().address

      state().calls
      |> Enum.find_value(fn {prefix, result} -> String.starts_with?(data, prefix) && result end)
      |> case do
        nil -> {:error, :unexpected_call}
        result -> result
      end
    end

    defp rpc_response("eth_getTransactionReceipt", [hash]),
      do: Map.fetch!(state().receipts, String.downcase(hash))

    defp rpc_response("eth_getTransactionByHash", [hash]),
      do: Map.fetch!(state().transactions, String.downcase(hash))

    defp rpc_response(_method, _params), do: {:error, :unexpected_request}

    defp block_hash(number), do: Map.get(state().blocks, number, state().safe_hash)

    defp same_block!(%{blockHash: hash, requireCanonical: true}) do
      true = hash in [state().safe_hash | Map.values(state().blocks)]
    end

    defp state, do: Process.get(:treasury_rpc_state)
  end

  setup do
    previous_client = Application.get_env(:autolaunch, :autolaunch_treasury_chain_client)
    previous_http = Application.get_env(:autolaunch, :autolaunch_treasury_http_client)
    previous_url = Application.get_env(:autolaunch, :base_read_rpc_url)

    on_exit(fn ->
      restore(:autolaunch_treasury_chain_client, previous_client)
      restore(:autolaunch_treasury_http_client, previous_http)
      restore(:base_read_rpc_url, previous_url)
      Application.delete_env(:autolaunch, :test_autolaunch_treasury_observation)
    end)

    :ok
  end

  test "THE_CONFIGURED_CLIENT_OWNS_BOTH_OBSERVATION_AND_CANONICAL_RECHECK" do
    Client.install()
    address = "0x9999999999999999999999999999999999999999"

    assert {:ok, observation} = TreasuryChainClient.observe(address, %{})
    assert observation.admitted_safe?
    assert TreasuryChainClient.canonical?(observation.block.number, observation.block.hash)

    Client.install(canonical?: false)
    refute TreasuryChainClient.canonical?(observation.block.number, observation.block.hash)
  end

  test "PRODUCTION_READS_ONE_CANONICAL_EIP_1898_BLOCK_AND_NEVER_GUESSES_CODE" do
    Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
    Application.put_env(:autolaunch, :autolaunch_treasury_http_client, HttpClient)
    Application.put_env(:autolaunch, :base_read_rpc_url, "https://provider.invalid")

    for runtime <- [
          "0x",
          "0xef0100" <> String.duplicate("11", 20),
          "0xef0100" <> String.duplicate("11", 19),
          "0x6001600055"
        ] do
      Process.put(:treasury_rpc_state, production_fixture(runtime_code: runtime))
      assert {:ok, observation} = TreasuryChainClient.observe(@address, %{})
      assert observation.runtime_code == runtime
      refute observation.admitted_safe?

      assert_received {:treasury_rpc, "eth_getCode",
                       [@address, %{blockHash: @safe_hash, requireCanonical: true}]}
    end

    assert TreasuryChainClient.canonical?(0x30, @safe_hash)

    Process.put(
      :treasury_rpc_state,
      production_fixture(safe_hash: "0x" <> String.duplicate("cc", 32), runtime_code: "0x")
    )

    refute TreasuryChainClient.canonical?(0x20, @safe_hash)
  end

  test "PRODUCTION_CANONICAL_RECHECK_REQUIRES_THE_EXACT_BOUND_HEADER_IDENTITY" do
    mutations = [
      non_map: nil,
      missing_number: %{"hash" => @safe_hash},
      wrong_number: %{"number" => "0x31", "hash" => @safe_hash},
      malformed_number: %{"number" => "30", "hash" => @safe_hash},
      noncanonical_number: %{"number" => "0x030", "hash" => @safe_hash},
      missing_hash: %{"number" => "0x30"},
      short_hash: %{"number" => "0x30", "hash" => "0x12"},
      nonhex_hash: %{"number" => "0x30", "hash" => "0x" <> String.duplicate("zz", 32)},
      wrong_hash: %{"number" => "0x30", "hash" => "0x" <> String.duplicate("cc", 32)}
    ]

    production_client(production_fixture())
    assert TreasuryChainClient.canonical?(0x30, @safe_hash)

    for {name, header} <- mutations do
      production_client(put_in(production_fixture().headers["0x30"], header))

      refute TreasuryChainClient.canonical?(0x30, @safe_hash),
             "expected #{name} bound header identity to fail closed"
    end
  end

  test "PRODUCTION_DECODES_THE_PINNED_SAFE_WITH_ZERO_OPTIONAL_SLOTS_AND_RECEIPT_EVIDENCE" do
    production_client(production_fixture())

    for {key, hash} <- Enum.zip([:usdc, :regent, :outbound], @evidence_hashes) do
      result = TreasuryChainClient.observe(@address, Map.put(empty_evidence(), key, hash))

      assert match?({:ok, _single_receipt}, result),
             "expected #{key} receipt to decode, got #{inspect(result)} after #{inspect(Process.info(self(), :messages))}"
    end

    assert {:ok, observation} =
             TreasuryChainClient.observe(@address, %{
               usdc: evidence_hash(0),
               regent: evidence_hash(1),
               outbound: evidence_hash(2)
             })

    assert observation.admitted_safe?
    assert observation.safe_singleton == @singleton
    assert observation.owners == @owners
    assert observation.threshold == 2
    assert observation.modules == []
    assert observation.guard == @zero
    assert observation.fallback_handler == @zero
    assert observation.fallback_admitted?
    assert observation.evidence.usdc.verified
    assert observation.evidence.regent.verified
    assert observation.evidence.outbound.verified
  end

  test "PRODUCTION_REJECTS_ZERO_REQUIRED_SINGLETON_OR_OWNER" do
    production_client(production_fixture(singleton_storage: @zero))
    assert {:error, _reason} = TreasuryChainClient.observe(@address, %{})

    production_client(production_fixture(owners: [@zero | tl(@owners)]))
    assert {:error, _reason} = TreasuryChainClient.observe(@address, %{})
  end

  test "PRODUCTION_HASHES_THE_COMPATIBILITY_FALLBACK_AT_THE_SAME_BLOCK_AND_REJECTS_DRIFT" do
    production_client(production_fixture(fallback_storage: @fallback, fallback_runtime: "0x00"))

    assert {:ok, observation} = TreasuryChainClient.observe(@address, empty_evidence())
    assert observation.fallback_handler == @fallback
    refute observation.fallback_admitted?

    assert_received {:treasury_rpc, "eth_getCode",
                     [@fallback, %{blockHash: @safe_hash, requireCanonical: true}]}
  end

  test "DUPLICATE_CUSTODY_EVIDENCE_HASHES_FAIL_BEFORE_ANY_PROVIDER_REQUEST" do
    hash = evidence_hash(2)
    number = "0x22"
    block_hash = receipt_hash(2)

    state =
      production_fixture()
      |> put_in([:receipts, hash, "logs"], [
        transfer_log(hash, number, block_hash),
        regent_log(hash, number, block_hash),
        execution_log(hash, number, block_hash)
      ])

    production_client(state)
    uppercase_hash = "0x" <> (hash |> String.slice(2, 64) |> String.upcase())

    assert {:error, :treasury_evidence_hash_invalid} =
             TreasurySecurity.observe(
               @address,
               %{usdc: uppercase_hash, regent: hash, outbound: hash},
               %System{}
             )

    refute_received {:treasury_rpc, _method, _params}
  end

  test "PRODUCTION_REJECTS_TRANSACTION_RECEIPT_AND_SELECTED_LOG_IDENTITY_DRIFT" do
    mutations = [
      transaction_block_hash: &put_in(&1.transactions[evidence_hash(0)]["blockHash"], @safe_hash),
      transaction_block_number: &put_in(&1.transactions[evidence_hash(0)]["blockNumber"], "0x21"),
      receipt_transaction_hash:
        &put_in(
          &1.receipts[evidence_hash(0)]["transactionHash"],
          "0x" <> String.duplicate("22", 32)
        ),
      log_transaction_hash:
        &put_in(&1.receipts[evidence_hash(0)]["logs"], [
          transfer_log("0x" <> String.duplicate("22", 32), "0x20", receipt_hash(0))
        ]),
      log_block_number:
        &put_in(&1.receipts[evidence_hash(0)]["logs"], [
          transfer_log(evidence_hash(0), "0x21", receipt_hash(0))
        ]),
      log_block_hash:
        &put_in(&1.receipts[evidence_hash(0)]["logs"], [
          transfer_log(evidence_hash(0), "0x20", @safe_hash)
        ]),
      header_block_number: &put_in(&1.header_numbers["0x20"], "0x21")
    ]

    for {name, mutate} <- mutations do
      production_client(mutate.(production_fixture()))

      assert {:error, :treasury_evidence_invalid} =
               TreasuryChainClient.observe(@address, %{usdc: evidence_hash(0)}),
             "expected #{name} drift to fail closed"
    end
  end

  test "PRODUCTION_REJECTS_MISSING_MALFORMED_OR_NONCANONICAL_EVIDENCE_LOG_INDEXES" do
    mutations = [
      missing: &Map.delete(&1, "logIndex"),
      malformed: &Map.put(&1, "logIndex", "not-a-quantity"),
      negative: &Map.put(&1, "logIndex", "0x-1"),
      noncanonical: &Map.put(&1, "logIndex", "0x00")
    ]

    for {key, index} <- [usdc: 0, outbound: 2], {name, mutate} <- mutations do
      hash = evidence_hash(index)

      state =
        update_in(production_fixture(), [:receipts, hash, "logs"], fn [log] ->
          [mutate.(log)]
        end)

      production_client(state)

      assert {:error, :invalid_chain_response} =
               TreasurySecurity.observe(
                 @address,
                 Map.put(empty_evidence(), key, hash),
                 %System{}
               ),
             "expected #{key} #{name} logIndex to fail closed"
    end

    assert {:ok, []} = Autolaunch.list_treasury_security_reports(@address, actor: nil)
  end

  defp production_client(state) do
    Application.delete_env(:autolaunch, :autolaunch_treasury_chain_client)
    Application.put_env(:autolaunch, :autolaunch_treasury_http_client, HttpClient)
    Application.put_env(:autolaunch, :base_read_rpc_url, "https://provider.invalid")
    Process.put(:treasury_rpc_state, state)
  end

  defp production_fixture(overrides \\ []) do
    runtime_code = Keyword.get(overrides, :runtime_code, @proxy_runtime)
    singleton_storage = Keyword.get(overrides, :singleton_storage, @singleton)
    owners = Keyword.get(overrides, :owners, @owners)
    fallback_storage = Keyword.get(overrides, :fallback_storage, @zero)
    fallback_runtime = Keyword.get(overrides, :fallback_runtime, "0x")
    safe_hash = Keyword.get(overrides, :safe_hash, @safe_hash)

    blocks = Map.new(0..2, &{"0x2#{&1}", receipt_hash(&1)})

    transactions =
      Map.new(0..2, fn index ->
        hash = evidence_hash(index)

        transaction = %{
          "hash" => hash,
          "blockNumber" => "0x2#{index}",
          "blockHash" => receipt_hash(index)
        }

        transaction =
          if index == 2,
            do: Map.merge(transaction, %{"to" => @address, "input" => exec_input()}),
            else: transaction

        {hash, transaction}
      end)

    receipts =
      Map.new(0..2, fn index ->
        hash = evidence_hash(index)
        number = "0x2#{index}"
        block_hash = receipt_hash(index)

        log =
          case index do
            0 -> transfer_log(hash, number, block_hash)
            1 -> regent_log(hash, number, block_hash)
            2 -> execution_log(hash, number, block_hash)
          end

        {hash,
         %{
           "transactionHash" => hash,
           "status" => "0x1",
           "blockNumber" => number,
           "blockHash" => block_hash,
           "logs" => [log]
         }}
      end)

    %{
      address: @address,
      safe_hash: safe_hash,
      blocks: blocks,
      headers: %{},
      header_numbers: %{},
      codes: %{
        @address => runtime_code,
        @singleton => singleton_runtime(),
        @fallback => fallback_runtime
      },
      storage: %{
        "0x0" => word_address(singleton_storage),
        @guard_slot => word_address(@zero),
        @fallback_slot => word_address(fallback_storage)
      },
      calls: [
        {"0xffa1ad74", abi_string("1.4.1")},
        {"0xa0e67e2b", abi_addresses(owners)},
        {"0xe75235b8", "0x" <> word(2)},
        {"0xcc2f8452",
         "0x" <> word(64) <> String.slice(word_address(@sentinel), 2, 64) <> word(0)}
      ],
      transactions: transactions,
      receipts: receipts
    }
  end

  defp transfer_log(transaction_hash, block_number, block_hash),
    do:
      token_log(
        "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        transaction_hash,
        block_number,
        block_hash
      )

  defp regent_log(transaction_hash, block_number, block_hash),
    do:
      token_log(
        "0x6f89bca4ea5931edfcb09786267b251dee752b07",
        transaction_hash,
        block_number,
        block_hash
      )

  defp token_log(token, transaction_hash, block_number, block_hash) do
    %{
      "address" => token,
      "topics" => [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        word_address("0x5555555555555555555555555555555555555555"),
        word_address(@address)
      ],
      "data" => "0x" <> word(1),
      "logIndex" => "0x0",
      "transactionHash" => transaction_hash,
      "blockNumber" => block_number,
      "blockHash" => block_hash
    }
  end

  defp execution_log(transaction_hash, block_number, block_hash) do
    %{
      "address" => @address,
      "topics" => [
        "0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e",
        "0x" <> String.duplicate("66", 32)
      ],
      "data" => "0x" <> word(1),
      "logIndex" => "0x2",
      "transactionHash" => transaction_hash,
      "blockNumber" => block_number,
      "blockHash" => block_hash
    }
  end

  defp exec_input do
    "0x6a761202" <>
      String.slice(word_address("0x4444444444444444444444444444444444444444"), 2, 64) <>
      word(1) <>
      word(320) <>
      word(0) <>
      String.duplicate(word(0), 6) <>
      word(1) <> String.pad_trailing("ff", 64, "0")
  end

  defp singleton_runtime do
    @singleton_runtime_gzip
    |> Base.decode64!()
    |> :zlib.gunzip()
    |> String.trim()
  end

  defp abi_string(value) do
    encoded = Base.encode16(value, case: :lower)
    "0x" <> word(32) <> word(byte_size(value)) <> String.pad_trailing(encoded, 64, "0")
  end

  defp abi_addresses(addresses),
    do:
      "0x" <>
        word(32) <>
        word(length(addresses)) <>
        Enum.map_join(addresses, &String.slice(word_address(&1), 2, 64))

  defp word_address("0x" <> address), do: "0x" <> String.duplicate("0", 24) <> address
  defp word(value), do: value |> Integer.to_string(16) |> String.pad_leading(64, "0")
  defp empty_evidence, do: %{usdc: nil, regent: nil, outbound: nil}
  defp evidence_hash(index), do: Enum.at(@evidence_hashes, index)
  defp receipt_hash(index), do: Enum.at(@receipt_hashes, index)

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
