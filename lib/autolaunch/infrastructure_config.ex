defmodule Autolaunch.InfrastructureConfig do
  @moduledoc false

  alias Autolaunch.BaseChain

  @uint40_max 1_099_511_627_775
  @convex_min_auction_duration_blocks 13

  @launch_address_keys [
    :cca_factory_address,
    :pool_manager_address,
    :position_manager_address,
    :usdc_address,
    :revenue_share_factory_address,
    :revenue_ingress_factory_address,
    :lbp_strategy_factory_address,
    :token_factory_address
  ]

  @verifier_address_keys [
    :pool_manager_addresses,
    :usdc_addresses,
    :revenue_share_factory_addresses,
    :revenue_ingress_factory_addresses,
    :lbp_strategy_factory_addresses,
    :chain_rpc_urls,
    :erc8004_subgraph_urls
  ]

  @launch_script_inputs [
    {:factory_owner_address, "AUTOLAUNCH_FACTORY_OWNER_ADDRESS", :address},
    {:strategy_operator, "STRATEGY_OPERATOR", :address},
    {:official_pool_fee, "OFFICIAL_POOL_FEE", {:integer, min: 0}},
    {:official_pool_tick_spacing, "OFFICIAL_POOL_TICK_SPACING", {:integer, min: 1}},
    {:cca_tick_spacing_q96, "CCA_TICK_SPACING_Q96", {:integer, min: 1}},
    {:cca_floor_price_q96, "CCA_FLOOR_PRICE_Q96", {:integer, min: 1}},
    {:auction_duration_blocks, "AUCTION_DURATION_BLOCKS",
     {:integer, min: @convex_min_auction_duration_blocks, max: @uint40_max}},
    {:cca_prebid_blocks, "CCA_PREBID_BLOCKS", {:integer, min: 0, max: @uint40_max}},
    {:cca_final_block_bps, "CCA_FINAL_BLOCK_BPS", {:integer, min: 2_000, max: 4_000}},
    {:cca_start_block_offset, "CCA_START_BLOCK_OFFSET", {:integer, min: 0}},
    {:cca_claim_block_offset, "CCA_CLAIM_BLOCK_OFFSET", {:integer, min: 0}},
    {:lbp_migration_block_offset, "LBP_MIGRATION_BLOCK_OFFSET", {:integer, min: 0}},
    {:lbp_sweep_block_offset, "LBP_SWEEP_BLOCK_OFFSET", {:integer, min: 0}}
  ]

  def launch, do: Application.get_env(:autolaunch, :launch, [])
  def regent_staking, do: Application.get_env(:autolaunch, :regent_staking, [])

  def launch_address_keys, do: @launch_address_keys
  def verifier_address_keys, do: @verifier_address_keys
  def launch_script_inputs, do: @launch_script_inputs
  def base_chain_ids, do: BaseChain.supported_chain_ids()
  def base_chains, do: BaseChain.chains()

  def launch_chain_id do
    launch()
    |> Keyword.get(:chain_id, BaseChain.base_sepolia_chain_id())
    |> normalize_base_chain_id()
  end

  def launch_chain_id! do
    case launch_chain_id() do
      {:ok, chain_id} -> chain_id
      {:error, reason} -> raise ArgumentError, "invalid launch chain: #{inspect(reason)}"
    end
  end

  def regent_staking_chain_id do
    regent_staking()
    |> Keyword.get(:chain_id, BaseChain.base_mainnet_chain_id())
    |> normalize_base_chain_id()
  end

  def base_chain?(chain_id), do: BaseChain.supported_chain_id?(chain_id)

  def launch_rpc_url do
    launch()
    |> text_value(:rpc_url)
    |> required_text(:missing_rpc_url)
  end

  def regent_staking_rpc_url do
    regent_staking()
    |> text_value(:rpc_url)
    |> required_text(:missing_rpc_url)
  end

  def rpc_url(chain_id, opts \\ []) do
    source = Keyword.get(opts, :source, :launch)

    cond do
      source == :regent_staking and regent_staking_chain?(chain_id) ->
        regent_staking_rpc_url()

      present?(chain_text(:chain_rpc_urls, chain_id)) ->
        {:ok, chain_text(:chain_rpc_urls, chain_id)}

      launch_chain?(chain_id) ->
        launch_rpc_url()

      regent_staking_chain?(chain_id) ->
        regent_staking_rpc_url()

      true ->
        {:error, :invalid_chain_id}
    end
  end

  def launch_value(key), do: Keyword.get(launch(), key)
  def regent_staking_value(key), do: Keyword.get(regent_staking(), key)

  def launch_text(key), do: text_value(launch(), key)
  def regent_staking_text(key), do: text_value(regent_staking(), key)

  def launch_address(key), do: normalize_address(launch_value(key))
  def regent_staking_address(key), do: normalize_address(regent_staking_value(key))

  def chain_text(key, chain_id) do
    case Keyword.get(launch(), key, %{}) do
      %{} = values -> normalize_text(Map.get(values, chain_id))
      _ -> nil
    end
  end

  def chain_address(key, chain_id), do: normalize_address(chain_text(key, chain_id))

  def launch_missing_address_keys do
    Enum.reject(@launch_address_keys, fn key ->
      configured_address?(launch_value(key))
    end)
  end

  def configured_address?(value), do: not is_nil(normalize_address(value))
  def present?(value), do: not is_nil(normalize_text(value))

  def valid_script_input?(key, :address), do: configured_address?(launch_value(key))

  def valid_script_input?(key, {:integer, opts}) do
    min = Keyword.fetch!(opts, :min)
    max = Keyword.get(opts, :max)

    case normalize_integer(launch_value(key)) do
      value when is_integer(value) -> value >= min and (is_nil(max) or value <= max)
      nil -> false
    end
  end

  defp launch_chain?(chain_id) do
    case launch_chain_id() do
      {:ok, ^chain_id} -> true
      _ -> false
    end
  end

  defp regent_staking_chain?(chain_id) do
    case regent_staking_chain_id() do
      {:ok, ^chain_id} -> true
      _ -> false
    end
  end

  defp normalize_base_chain_id(value) do
    chain_id = BaseChain.normalize_chain_id(value)

    if BaseChain.supported_chain_id?(chain_id),
      do: {:ok, chain_id},
      else: {:error, :invalid_chain_id}
  end

  defp text_value(config, key) do
    config
    |> Keyword.get(key)
    |> normalize_text()
  end

  defp required_text(nil, reason), do: {:error, reason}
  defp required_text(value, _reason), do: {:ok, value}

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(_value), do: nil

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp normalize_address(value) when is_binary(value) do
    address = String.downcase(String.trim(value))

    if Regex.match?(~r/^0x[0-9a-f]{40}$/, address),
      do: address,
      else: nil
  end

  defp normalize_address(_value), do: nil
end
