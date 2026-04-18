defmodule Autolaunch.ReleaseDeployVerifierTestSupport do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Autolaunch.Launch.Job
  alias Autolaunch.Repo

  @launch_stack_deployed_topic0 "0x0f4620e4f0d6524b6aca672f72348ff2535a365b816545538f83084e8d073077"

  def chain_id, do: 84_532
  def job_id, do: "job_verify_deploy"
  def tx_hash, do: "0x" <> String.duplicate("a", 64)
  def pool_id, do: "0x" <> String.duplicate("b", 64)
  def subject_id, do: "0x" <> String.duplicate("c", 64)

  def address(:owner), do: "0x1111111111111111111111111111111111111111"
  def address(:controller), do: "0x2222222222222222222222222222222222222222"
  def address(:revenue_share_factory), do: "0x3333333333333333333333333333333333333333"
  def address(:revenue_ingress_factory), do: "0x4444444444444444444444444444444444444444"
  def address(:agent_safe), do: "0x5555555555555555555555555555555555555555"
  def address(:fee_registry), do: "0x6666666666666666666666666666666666666666"
  def address(:fee_vault), do: "0x7777777777777777777777777777777777777777"
  def address(:hook), do: "0x8888888888888888888888888888888888888888"
  def address(:strategy), do: "0x9999999999999999999999999999999999999999"
  def address(:subject_registry), do: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  def address(:splitter), do: "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  def address(:default_ingress), do: "0xcccccccccccccccccccccccccccccccccccccccc"
  def address(:launch_token), do: "0xdddddddddddddddddddddddddddddddddddddddd"
  def address(:usdc), do: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  def address(:regent_recipient), do: "0xffffffffffffffffffffffffffffffffffffffff"
  def address(:pool_manager), do: "0x1212121212121212121212121212121212121212"
  def address(:pending_owner), do: "0x1313131313131313131313131313131313131313"
  def address(:currency0), do: address(:launch_token)
  def address(:currency1), do: address(:usdc)

  def launch_config(previous \\ []) do
    Keyword.merge(previous,
      usdc_address: address(:usdc),
      pool_manager_address: address(:pool_manager),
      revenue_share_factory_address: address(:revenue_share_factory),
      revenue_ingress_factory_address: address(:revenue_ingress_factory)
    )
  end

  def insert_ready_job! do
    now = DateTime.utc_now()

    Repo.delete_all(from job in Job, where: job.job_id == ^job_id())

    {:ok, job} =
      %Job{}
      |> Job.create_changeset(%{
        job_id: job_id(),
        owner_address: address(:owner),
        agent_id: "84532:4242",
        token_name: "Atlas Coin",
        token_symbol: "ATLAS",
        agent_safe_address: address(:agent_safe),
        network: "base-sepolia",
        chain_id: chain_id(),
        status: "ready",
        step: "ready",
        total_supply: "100000000000",
        message: "signed",
        siwa_nonce: "verify-deploy-nonce",
        siwa_signature: "verify-deploy-signature",
        issued_at: now
      })
      |> Repo.insert()

    job
    |> Job.update_changeset(%{
      token_address: address(:launch_token),
      strategy_address: address(:strategy),
      hook_address: address(:hook),
      launch_fee_registry_address: address(:fee_registry),
      launch_fee_vault_address: address(:fee_vault),
      subject_registry_address: address(:subject_registry),
      subject_id: subject_id(),
      revenue_share_splitter_address: address(:splitter),
      default_ingress_address: address(:default_ingress),
      pool_id: pool_id(),
      tx_hash: tx_hash()
    })
    |> Repo.update!()
  end

  def set_rpc_mode(mode) do
    Application.put_env(:autolaunch, :release_deploy_verifier_rpc_mode, mode)
  end

  defmodule Rpc do
    @moduledoc false

    alias Autolaunch.Contracts.Abi
    alias Autolaunch.ReleaseDeployVerifierTestSupport, as: Support

    def eth_call(chain_id, to, data) when chain_id == 84_532 do
      address = normalize(to)
      selector = String.slice(data, 0, 10)

      cond do
        address == Support.address(:controller) and selector == Abi.selector(:owner) ->
          {:ok, encode_address_result(Support.address(:owner))}

        address in [
          Support.address(:fee_registry),
          Support.address(:fee_vault),
          Support.address(:hook)
        ] and
            selector == Abi.selector(:owner) ->
          {:ok, encode_address_result(Support.address(:agent_safe))}

        address == Support.address(:fee_vault) and selector == Abi.selector(:pending_owner) ->
          {:ok, encode_address_result(pending_owner_for_fee_vault())}

        address in [Support.address(:fee_registry), Support.address(:hook)] and
            selector == Abi.selector(:pending_owner) ->
          {:ok, encode_address_result(zero_address())}

        address in [
          Support.address(:revenue_share_factory),
          Support.address(:revenue_ingress_factory)
        ] and
            selector == Abi.selector(:authorized_creators) ->
          {:ok, encode_bool_result(false)}

        address == Support.address(:fee_vault) and
            selector == Abi.selector(:canonical_launch_token) ->
          {:ok, encode_address_result(Support.address(:launch_token))}

        address == Support.address(:fee_vault) and
            selector == Abi.selector(:canonical_quote_token) ->
          {:ok, encode_address_result(Support.address(:usdc))}

        address == Support.address(:strategy) and selector == Abi.selector(:migrated) ->
          {:ok, encode_bool_result(true)}

        address == Support.address(:strategy) and selector == Abi.selector(:migrated_pool_id) ->
          {:ok, encode_bytes32_result(Support.pool_id())}

        address == Support.address(:strategy) and selector == Abi.selector(:migrated_position_id) ->
          {:ok, encode_uint_result(17)}

        address == Support.address(:strategy) and selector == Abi.selector(:migrated_liquidity) ->
          {:ok, encode_uint_result(1_000_000)}

        address == Support.address(:fee_vault) and selector == Abi.selector(:hook) ->
          {:ok, encode_address_result(Support.address(:hook))}

        address == Support.address(:fee_registry) and selector == Abi.selector(:get_pool_config) ->
          {:ok, encode_pool_config_result()}

        address == Support.address(:subject_registry) and selector == Abi.selector(:get_subject) ->
          {:ok, encode_subject_config_result()}

        address == Support.address(:revenue_ingress_factory) and
            selector == Abi.selector(:default_ingress_of_subject) ->
          {:ok, encode_address_result(Support.address(:default_ingress))}

        true ->
          {:error, {:unexpected_call, chain_id, to, selector}}
      end
    end

    def eth_call(chain_id, _to, _data), do: {:error, {:unexpected_chain_id, chain_id}}

    def tx_receipt(chain_id, tx_hash) do
      if chain_id == 84_532 and tx_hash == Support.tx_hash() do
        {:ok,
         %{
           logs: [
             %{
               address: Support.address(:controller),
               topics: [Support.launch_stack_deployed_topic0()],
               data: "0x"
             }
           ]
         }}
      else
        {:ok, nil}
      end
    end

    def tx_by_hash(_chain_id, _tx_hash), do: {:ok, nil}
    def get_logs(_chain_id, _filter), do: {:ok, []}

    defp pending_owner_for_fee_vault do
      case Application.get_env(:autolaunch, :release_deploy_verifier_rpc_mode, :healthy) do
        :pending_owner -> Support.address(:pending_owner)
        _ -> zero_address()
      end
    end

    defp encode_pool_config_result do
      words = [
        encode_address_word(Support.address(:launch_token)),
        encode_address_word(Support.address(:usdc)),
        encode_address_word(Support.address(:splitter)),
        encode_address_word(Support.address(:regent_recipient)),
        encode_address_word(Support.address(:currency0)),
        encode_address_word(Support.address(:currency1)),
        encode_uint_word(10_000),
        encode_uint_word(60),
        encode_address_word(Support.address(:pool_manager)),
        encode_address_word(Support.address(:hook)),
        encode_uint_word(1)
      ]

      "0x" <> Enum.join(words)
    end

    defp encode_subject_config_result do
      label = "Atlas"
      label_hex = Base.encode16(label, case: :lower)

      padded_size =
        if rem(byte_size(label), 32) == 0,
          do: byte_size(label),
          else: byte_size(label) + 32 - rem(byte_size(label), 32)

      words = [
        encode_address_word(Support.address(:launch_token)),
        encode_address_word(Support.address(:splitter)),
        encode_address_word(Support.address(:agent_safe)),
        encode_uint_word(1),
        encode_uint_word(160)
      ]

      tail = [
        encode_uint_word(byte_size(label)),
        String.pad_trailing(label_hex, padded_size * 2, "0")
      ]

      "0x" <> Enum.join(words ++ tail)
    end

    defp encode_address_result(address), do: "0x" <> encode_address_word(address)
    defp encode_bool_result(value), do: encode_uint_result(if(value, do: 1, else: 0))
    defp encode_uint_result(value), do: "0x" <> encode_uint_word(value)
    defp encode_bytes32_result("0x" <> hex), do: "0x" <> String.downcase(hex)

    defp encode_address_word("0x" <> hex) do
      hex
      |> String.downcase()
      |> String.pad_leading(64, "0")
    end

    defp encode_uint_word(value) when is_integer(value) and value >= 0 do
      value
      |> Integer.to_string(16)
      |> String.pad_leading(64, "0")
    end

    defp normalize(value) when is_binary(value), do: String.downcase(value)
    defp zero_address, do: "0x" <> String.duplicate("0", 40)
  end

  def launch_stack_deployed_topic0, do: @launch_stack_deployed_topic0
end
