defmodule Autolaunch.LabTest do
  use ExUnit.Case, async: true

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
