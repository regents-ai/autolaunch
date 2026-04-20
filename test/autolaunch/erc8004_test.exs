defmodule Autolaunch.ERC8004Test do
  use ExUnit.Case, async: false

  alias Autolaunch.ERC8004

  @wallet "0x1111111111111111111111111111111111111111"
  @sepolia_registry "0x8004a818bfb912233c491871b3d84c89a494bd9e"
  @mainnet_registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"

  defmodule GraphStub do
    import Plug.Conn

    @wallet "0x1111111111111111111111111111111111111111"

    def init(opts), do: opts

    def call(conn, _opts) do
      agents =
        case conn.request_path do
          "/84532" -> [agent("84532", "42", "Atlas Sepolia")]
          "/8453" -> [agent("8453", "99", "Atlas Base")]
          _ -> []
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"data" => %{"agents" => agents}}))
    end

    defp agent(chain_id, agent_id, name) do
      %{
        "id" => "#{chain_id}:#{agent_id}",
        "chainId" => chain_id,
        "agentId" => agent_id,
        "owner" => @wallet,
        "operators" => [],
        "agentWallet" => @wallet,
        "agentURI" => "https://example.test/#{chain_id}/#{agent_id}",
        "registrationFile" => %{
          "id" => "registration:#{chain_id}:#{agent_id}",
          "name" => name,
          "description" => "#{name} registration",
          "image" => "https://example.test/#{chain_id}/#{agent_id}.png",
          "active" => true,
          "ens" => String.downcase("#{name}.eth"),
          "webEndpoint" => "https://example.test/#{chain_id}/#{agent_id}/profile"
        }
      }
    end
  end

  setup_all do
    original_launch = Application.get_env(:autolaunch, :launch, [])
    port = available_port()

    start_supervised!({Bandit, plug: GraphStub, ip: {127, 0, 0, 1}, port: port})

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(original_launch,
        erc8004_subgraph_urls: %{
          84_532 => "http://127.0.0.1:#{port}/84532",
          8_453 => "http://127.0.0.1:#{port}/8453"
        },
        identity_registry_addresses: %{
          84_532 => @sepolia_registry,
          8_453 => @mainnet_registry
        }
      )
    )

    on_exit(fn -> Application.put_env(:autolaunch, :launch, original_launch) end)

    :ok
  end

  test "list_accessible_identities returns identities from both configured Base chains" do
    identities = ERC8004.list_accessible_identities([@wallet], [84_532, 8_453])

    assert Enum.map(identities, & &1.agent_id) |> Enum.sort() == ["84532:42", "8453:99"]
  end

  test "get_identities_by_agent_ids preserves both configured Base chains" do
    identities = ERC8004.get_identities_by_agent_ids(["84532:42", "8453:99"])

    assert Map.keys(identities) |> Enum.sort() == ["84532:42", "8453:99"]
    assert identities["84532:42"].registry_address == @sepolia_registry
    assert identities["8453:99"].registry_address == @mainnet_registry
  end

  test "identity_registry resolves both configured Base chains" do
    assert ERC8004.identity_registry(84_532) == @sepolia_registry
    assert ERC8004.identity_registry(8_453) == @mainnet_registry
  end

  test "list_accessible_identities skips chains missing a registry address" do
    original_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(original_launch,
        identity_registry_addresses: %{
          84_532 => @sepolia_registry,
          8_453 => ""
        }
      )
    )

    on_exit(fn -> Application.put_env(:autolaunch, :launch, original_launch) end)

    identities = ERC8004.list_accessible_identities([@wallet], [84_532, 8_453])

    assert Enum.map(identities, & &1.agent_id) == ["84532:42"]
  end

  test "get_identities_by_agent_ids ignores unsupported, blank, and partially configured chains" do
    original_launch = Application.get_env(:autolaunch, :launch, [])

    Application.put_env(
      :autolaunch,
      :launch,
      Keyword.merge(original_launch,
        identity_registry_addresses: %{
          84_532 => @sepolia_registry,
          8_453 => ""
        }
      )
    )

    on_exit(fn -> Application.put_env(:autolaunch, :launch, original_launch) end)

    identities =
      ERC8004.get_identities_by_agent_ids(["84532:42", "8453:99", "1:7", "8453:   ", "bad"])

    assert Map.keys(identities) == ["84532:42"]
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
