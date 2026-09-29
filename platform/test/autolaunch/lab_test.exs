defmodule Autolaunch.LabTest do
  use ExUnit.Case, async: false

  alias Autolaunch.{Lab, LabAbi}

  @address_keys ~w(
    cca_factory escrow_implementation factory governance_safe hook permit2 pool_manager
    position_manager receiver_implementation regent splitter_implementation strategy uerc20_factory
  )
  @abi_keys ~w(auction escrow factory hook permit2 receiver splitter strategy token)

  setup context do
    path = Path.join(System.tmp_dir!(), "ash-lab-#{context.test}.json")
    File.write!(path, Jason.encode!(valid_config()))
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "loads only the complete chain-31337 literal-loopback config", %{path: path} do
    assert {:ok, config} = Lab.load(path)
    assert config.rpc_url == "http://127.0.0.1:49713"
    assert config.chain_id == 31_337
    assert Map.keys(config.addresses) |> Enum.sort() == Enum.sort(@address_keys)
    assert Map.keys(config.abis) |> Enum.sort() == Enum.sort(@abi_keys)
  end

  test "rejects a relative path and non-loopback, wrong-chain, incomplete, and malformed configs",
       %{
         path: path
       } do
    assert {:error, :absolute_path_required} = Lab.load(Path.basename(path))

    for mutation <- [
          &put_in(&1, ["rpc_url"], "http://localhost:49713"),
          &put_in(&1, ["rpc_url"], "http://127.0.0.1:49713/path"),
          &put_in(&1, ["rpc_url"], "https://127.0.0.1:49713"),
          &put_in(&1, ["chain_id"], 8453),
          &update_in(&1, ["addresses"], fn addresses -> Map.delete(addresses, "factory") end),
          &update_in(&1, ["abis", "auction"], fn abi ->
            Enum.reject(abi, fn entry ->
              LabAbi.canonical_signature(entry) ==
                "submitBid(uint256,uint128,address,uint256,bytes)"
            end)
          end),
          &update_in(&1, ["abis", "auction"], fn abi ->
            Enum.map(abi, fn
              %{"name" => "submitBid", "inputs" => inputs} = entry when length(inputs) == 5 ->
                Map.put(entry, "stateMutability", "nonpayable")

              entry ->
                entry
            end)
          end),
          &update_in(&1, ["abis", "factory"], fn abi ->
            Enum.map(abi, fn
              %{"name" => "launch", "type" => "function"} = entry ->
                Map.put(entry, "outputs", [%{"type" => "address", "name" => "wrong"}])

              entry ->
                entry
            end)
          end),
          &update_in(&1, ["abis", "factory"], fn abi ->
            Enum.map(abi, fn
              %{"name" => "LaunchCreated", "inputs" => [first | rest]} = entry ->
                Map.put(entry, "inputs", [Map.put(first, "indexed", false) | rest])

              entry ->
                entry
            end)
          end)
        ] do
      File.write!(path, Jason.encode!(mutation.(valid_config())))
      assert {:error, _reason} = Lab.load(path)
    end

    File.write!(path, "not json")
    assert {:error, :invalid_json} = Lab.load(path)
  end

  test "rereads and compares exact network and relevant address bindings", %{path: path} do
    previous_enabled = Application.get_env(:autolaunch, :autolaunch_lab_enabled)
    previous_path = Application.get_env(:autolaunch, :autolaunch_lab_config_path)
    previous_run_id = Application.get_env(:autolaunch, :autolaunch_lab_run_id)
    Application.put_env(:autolaunch, :autolaunch_lab_enabled, true)
    Application.put_env(:autolaunch, :autolaunch_lab_config_path, path)
    Application.put_env(:autolaunch, :autolaunch_lab_run_id, "lab-binding-test")

    on_exit(fn ->
      restore(:autolaunch_lab_enabled, previous_enabled)
      restore(:autolaunch_lab_config_path, previous_path)
      restore(:autolaunch_lab_run_id, previous_run_id)
    end)

    config = Lab.current!()
    binding = Lab.binding(config, [:factory, :strategy])
    assert Lab.binding_matches?(binding, [:factory, :strategy])

    File.write!(
      path,
      valid_config()
      |> put_in(["addresses", "factory"], "0x2222222222222222222222222222222222222222")
      |> Jason.encode!()
    )

    refute Lab.binding_matches?(binding, [:factory, :strategy])
  end

  test "encodes calldata from the selected config ABI rather than a production ABI file" do
    abi = valid_config()["abis"]["auction"]

    data =
      LabAbi.encode(
        abi,
        "submitBid(uint256,uint128,address,uint256,bytes)",
        [10, 20, "0x1111111111111111111111111111111111111111", 9, "0x"]
      )

    assert String.starts_with?(
             data,
             LabAbi.selector("submitBid(uint256,uint128,address,uint256,bytes)")
           )

    assert byte_size(data) == 10 + 6 * 64
  end

  describe "price formatting" do
    test "a Q96 price is converted exactly, never through eighteen decimals" do
      floor = 79_228_162_514_264_337_593_543_900

      assert Decimal.equal?(Lab.price_decimal(Integer.pow(2, 96)), Decimal.new(1))
      assert Lab.format_price(Integer.pow(2, 95)) == "0.5"
      assert Lab.format_price(0) == "0"
      assert String.starts_with?(Lab.format_price(floor), "0.000999999999999999999999999")

      assert Lab.format_price(floor) ==
               "0.0009999999999999999999999993646703595967223962047236950068107574907116941176354885101318359375"
    end
  end

  defmodule BidSnapshotClient do
    def post(_url, opts) do
      request = opts[:json]
      send(self(), {:snapshot_rpc, request.method, request.params})

      result =
        case {request.method, request.params} do
          {"eth_chainId", _} ->
            "0x7a69"

          {"eth_getBlockByNumber", ["latest", false]} ->
            %{"number" => "0x20", "hash" => "0x" <> String.duplicate("ab", 32)}

          {"eth_getCode", _} ->
            "0x01"

          {"eth_call", [%{data: data}, _]} ->
            answer(data)
        end

      {:ok, %{status: 200, body: %{"result" => result}}}
    end

    defp answer(data) do
      selector = String.slice(data, 0, 10)

      names = [
        "currency()",
        "balanceOf(address)",
        "allowance(address,address)",
        "allowance(address,address,address)",
        "tickSpacing()",
        "floorPrice()",
        "checkpoint()",
        "MAX_BID_PRICE()",
        "ticks(uint256)"
      ]

      name = Enum.find(names, &(Autolaunch.LabAbi.selector(&1) == selector))

      words =
        case name do
          "currency()" ->
            [String.to_integer(String.duplicate("1", 40), 16)]

          "balanceOf(address)" ->
            [1000]

          "allowance(address,address)" ->
            [1000]

          "allowance(address,address,address)" ->
            [1000, 1000, 0]

          "tickSpacing()" ->
            [10]

          "floorPrice()" ->
            [10]

          "checkpoint()" ->
            [20, 0, 0, 0, 0, 0]

          "MAX_BID_PRICE()" ->
            [95]

          "ticks(uint256)" ->
            current = data |> String.slice(10, 64) |> String.to_integer(16)

            [
              Map.fetch!(
                %{10 => 30, 30 => 60, 60 => 80, 80 => 90, 90 => Integer.pow(2, 256) - 1},
                current
              ),
              0
            ]
        end

      "0x" <> Enum.map_join(words, &Autolaunch.BaseRpcStub.hex_word/1)
    end
  end

  test "snapshot uses aligned price for predecessor and pins every limit and read to one block",
       %{path: path} do
    config = [
      autolaunch_lab_enabled: true,
      autolaunch_lab_config_path: path,
      autolaunch_lab_run_id: "bid-snapshot-fixture",
      autolaunch_lab_http_client: BidSnapshotClient
    ]

    previous = Enum.map(config, fn {key, _} -> {key, Application.get_env(:autolaunch, key)} end)
    Enum.each(config, fn {key, value} -> Application.put_env(:autolaunch, key, value) end)
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore(key, value) end) end)

    assert {:ok, snapshot} =
             Autolaunch.LabBidChainClient.snapshot(%{
               auction: "0x2222222222222222222222222222222222222222",
               signer: "0x1111111111111111111111111111111111111111",
               max_price_q96: 88
             })

    assert snapshot.prev_tick_price_q96 == 60
    assert {:ok, 80} = Autolaunch.BidPrice.align(88, snapshot)
    calls = snapshot_calls([])

    assert Enum.uniq(Enum.map(calls, &elem(&1, 1))) == [
             %{blockHash: snapshot.block.hash, requireCanonical: true}
           ]

    tick_selector = LabAbi.selector("ticks(uint256)")

    ticks =
      for {data, _} <- calls,
          String.starts_with?(data, tick_selector),
          do: data |> String.slice(10, 64) |> String.to_integer(16)

    assert ticks == [10, 30, 60]
  end

  defp snapshot_calls(calls) do
    receive do
      {:snapshot_rpc, "eth_call", [%{data: data}, block]} ->
        snapshot_calls(calls ++ [{data, block}])

      {:snapshot_rpc, _, _} ->
        snapshot_calls(calls)
    after
      0 -> calls
    end
  end

  defp valid_config do
    required = LabAbi.requirements()

    abis =
      Map.new(@abi_keys, fn key ->
        entries = Enum.map(Map.get(required, key, []), &entry/1)
        {key, if(entries == [], do: [entry("placeholder()")], else: entries)}
      end)

    %{
      "rpc_url" => "http://127.0.0.1:49713",
      "chain_id" => 31_337,
      "addresses" => Map.new(@address_keys, &{&1, "0x1111111111111111111111111111111111111111"}),
      "abis" => abis
    }
  end

  defp entry({:f, {signature, mutability, outputs}}) do
    [name, arguments] = Regex.run(~r/\A([^()]+)\((.*)\)\z/, signature, capture: :all_but_first)

    %{
      "type" => "function",
      "name" => name,
      "inputs" => parse_types(arguments),
      "outputs" => Enum.flat_map(outputs, &parse_types/1),
      "stateMutability" => mutability
    }
  end

  defp entry({:e, {signature, indexed}}) do
    [name, arguments] = Regex.run(~r/\A([^()]+)\((.*)\)\z/, signature, capture: :all_but_first)

    inputs =
      arguments
      |> parse_types()
      |> Enum.zip(indexed)
      |> Enum.map(fn {input, indexed?} -> Map.put(input, "indexed", indexed?) end)

    %{"type" => "event", "name" => name, "inputs" => inputs, "anonymous" => false}
  end

  defp entry(signature) when is_binary(signature), do: entry({:f, {signature, "nonpayable", []}})

  defp parse_types(""), do: []

  defp parse_types(arguments) do
    arguments
    |> split_top_level()
    |> Enum.map(fn
      "(" <> tuple ->
        tuple = String.trim_trailing(tuple, ")")
        %{"type" => "tuple", "name" => "", "components" => parse_types(tuple)}

      type ->
        %{"type" => type, "name" => ""}
    end)
  end

  defp split_top_level(value) do
    {parts, current, _depth} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        "(", {parts, current, depth} -> {parts, current <> "(", depth + 1}
        ")", {parts, current, depth} -> {parts, current <> ")", depth - 1}
        ",", {parts, current, 0} -> {[current | parts], "", 0}
        char, {parts, current, depth} -> {parts, current <> char, depth}
      end)

    Enum.reverse([current | parts])
  end

  defp restore(key, nil), do: Application.delete_env(:autolaunch, key)
  defp restore(key, value), do: Application.put_env(:autolaunch, key, value)
end
