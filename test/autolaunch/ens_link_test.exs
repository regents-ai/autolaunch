defmodule Autolaunch.EnsLinkTest do
  use Autolaunch.DataCase, async: true

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.EnsLink
  alias Autolaunch.Repo

  defmodule RpcReady do
    @ens_registry "0x00000000000c2e074ec69a0dfb2997ba6c7d2e1e"
    @registry "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
    @resolver "0x226159d592e2b063810a10ebf6dcbada94ed68b8"
    @signer "0x1111111111111111111111111111111111111111"

    def eth_call(_rpc_url, to, data) do
      case {String.downcase(to), data} do
        {@ens_registry, "0x0178b8bf" <> _node} ->
          {:ok, address_word(@resolver)}

        {@ens_registry, "0x02571be3" <> _node} ->
          {:ok, address_word(@signer)}

        {@resolver, "0x59d1d43c" <> _rest} ->
          {:ok, encode_string("")}

        {@resolver, "0x01ffc9a7" <> "4920eeb0" <> _padding} ->
          {:ok, bool_word(true)}

        {@registry, "0x6352211e" <> _rest} ->
          {:ok, address_word(@signer)}

        {@registry, "0x081812fc" <> _rest} ->
          {:ok, address_word("0x0000000000000000000000000000000000000000")}

        {@registry, "0xc87b56dd" <> _rest} ->
          uri =
            "data:application/json," <>
              URI.encode_www_form(
                Jason.encode!(%{
                  "type" => "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
                  "name" => "Demo Agent",
                  "services" => [%{"name" => "ENS", "endpoint" => "old.eth", "version" => "v1"}]
                })
              )

          {:ok, encode_string(uri)}

        {@registry, "0xe985e9c5" <> _rest} ->
          {:ok, bool_word(false)}
      end
    end

    defp bool_word(true), do: "0x" <> String.pad_leading("1", 64, "0")
    defp bool_word(false), do: "0x" <> String.duplicate("0", 64)

    defp address_word(address) do
      "0x" <>
        String.pad_leading(String.replace_prefix(String.downcase(address), "0x", ""), 64, "0")
    end

    defp encode_string(value) do
      hex = Base.encode16(value, case: :lower)
      padding = rem(64 - rem(byte_size(hex), 64), 64)

      "0x" <>
        String.pad_leading("20", 64, "0") <>
        String.pad_leading(Integer.to_string(byte_size(value), 16), 64, "0") <>
        hex <> String.duplicate("0", padding)
    end
  end

  test "prepares bidirectional ENS link data for a linked wallet" do
    {:ok, human} =
      %HumanUser{}
      |> HumanUser.changeset(%{
        privy_user_id: "did:privy:test",
        wallet_address: "0x1111111111111111111111111111111111111111",
        wallet_addresses: ["0x1111111111111111111111111111111111111111"]
      })
      |> Repo.insert()

    assert {:ok, prepared} =
             EnsLink.prepare_bidirectional_link(human, %{
               "ens_name" => "vitalik.eth",
               "chain_id" => "1",
               "agent_id" => "42",
               "registry_address" => "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
               "rpc_url" => "https://example.invalid",
               "rpc_module" => RpcReady
             })

    assert prepared.plan.verify_status == :ens_record_missing
    assert prepared.ensip25.tx.to == "0x226159d592e2b063810a10ebf6dcbada94ed68b8"
    assert prepared.erc8004.tx.to == "0x8004a169fb4a3325136eb29fa0ceb6d2e539a432"
  end
end
