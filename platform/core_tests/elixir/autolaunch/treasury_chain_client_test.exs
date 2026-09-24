defmodule Autolaunch.TreasuryChainClientTest do
  use ExUnit.Case, async: false

  alias Autolaunch.{BaseRpcStub, TreasuryChainClient}

  @moduletag :capture_log

  @safe "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e"
  @safe_l2 "0x29fcb43b46531bca003ddc8fcb67ffe91900c762"
  @no_evidence %{usdc: nil, regent: nil, outbound: nil}

  # A Safe proxy on Base answering with the real proxy and SafeL2 1.4.1
  # bytecode, owned 2-of-3, with no modules, guard or fallback handler.
  defmodule SafeStub do
    @fixtures Path.expand("../fixtures/safe", __DIR__)
    @block %{"number" => "0x96", "hash" => "0x" <> String.duplicate("cd", 32)}
    @owners [
      "0x8c172ca4b5dd9449217c636a953727eacd690e37",
      "0x978bdbecb54c54800d01055df5a8f6af600bface",
      "0x1d0dcabaeb941823e51935f795be184abebf76df"
    ]

    def owners, do: @owners

    def install(singleton) do
      Application.put_env(:autolaunch, :treasury_stub_singleton, singleton)

      ExUnit.Callbacks.on_exit(fn ->
        Application.delete_env(:autolaunch, :treasury_stub_singleton)
      end)

      for {key, value} <- [
            autolaunch_treasury_http_client: __MODULE__,
            autolaunch_treasury_chain_client: TreasuryChainClient
          ] do
        previous = Application.get_env(:autolaunch, key)
        Application.put_env(:autolaunch, key, value)

        ExUnit.Callbacks.on_exit(fn ->
          if previous,
            do: Application.put_env(:autolaunch, key, previous),
            else: Application.delete_env(:autolaunch, key)
        end)
      end
    end

    def post(_url, options) do
      %{method: method, params: params} = options[:json]
      {:ok, %{status: 200, body: %{"result" => answer(method, params)}}}
    end

    defp answer("eth_chainId", _params), do: "0x2105"
    defp answer("eth_getBlockByNumber", _params), do: @block

    defp answer("eth_getCode", [address, _block]) do
      case String.downcase(address) do
        "0x9fa152b0eadbfe9a7c5c0a8e1d11784f22669a3e" -> fixture("proxy-1.4.1.hex")
        "0x29fcb43b46531bca003ddc8fcb67ffe91900c762" -> fixture("safe-l2-1.4.1.hex")
        _other -> "0x"
      end
    end

    defp answer("eth_getStorageAt", [_address, "0x0", _block]),
      do:
        "0x" <>
          BaseRpcStub.address_word(Application.fetch_env!(:autolaunch, :treasury_stub_singleton))

    defp answer("eth_getStorageAt", _params), do: "0x" <> BaseRpcStub.hex_word(0)

    defp answer("eth_call", [%{data: data}, _block]) do
      case String.slice(data, 0, 10) do
        # VERSION()
        "0xffa1ad74" ->
          "0x" <>
            words([32, 5]) <> String.pad_trailing(Base.encode16("1.4.1", case: :lower), 64, "0")

        # getOwners()
        "0xa0e67e2b" ->
          "0x" <> words([32, 3]) <> Enum.map_join(@owners, &BaseRpcStub.address_word/1)

        # getThreshold()
        "0xe75235b8" ->
          "0x" <> words([2])

        # getModulesPaginated(address,uint256): no modules, the sentinel next
        "0xcc2f8452" ->
          "0x" <> words([64, 1, 0])
      end
    end

    defp words(values), do: Enum.map_join(values, &BaseRpcStub.hex_word/1)
    defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> String.trim()
  end

  test "a Safe on the SafeL2 1.4.1 singleton the Safe app deploys on Base is an admitted Safe" do
    SafeStub.install(@safe_l2)

    assert {:ok, observation} = TreasuryChainClient.observe(@safe, @no_evidence)

    assert %{
             admitted_safe?: true,
             safe_singleton: @safe_l2,
             safe_version: "1.4.1",
             threshold: 2,
             modules: [],
             fallback_admitted?: true
           } = observation

    assert observation.owners == SafeStub.owners()
  end

  test "a Safe proxy on a singleton the manifest does not admit is refused" do
    SafeStub.install("0x" <> String.duplicate("77", 20))

    assert {:error, :treasury_safe_evidence_mismatch} =
             TreasuryChainClient.observe(@safe, @no_evidence)
  end
end
