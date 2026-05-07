defmodule Autolaunch.RegentStaking do
  @moduledoc false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.CCA.Rpc
  alias Autolaunch.Contracts.ActionParams
  alias Autolaunch.Evm
  alias Autolaunch.InfrastructureConfig
  alias Autolaunch.RegentStaking.Abi

  @usdc_decimals 6
  @token_decimals 18
  @base_chain_id 8_453
  @base_chain_label "Base"
  @ethereum_mainnet_chain_id 1
  @zero_address "0x0000000000000000000000000000000000000000"

  def overview(current_human \\ nil) do
    with {:ok, cfg} <- config(),
         {:ok, state} <- load_state(cfg, primary_wallet_address(current_human)) do
      {:ok, state}
    end
  end

  def account(address, current_human \\ nil) do
    with {:ok, cfg} <- config(),
         {:ok, wallet_address} <- normalize_required_address(address),
         {:ok, state} <- load_state(cfg, wallet_address) do
      {:ok, Map.put(state, :connected_wallet_address, primary_wallet_address(current_human))}
    end
  end

  def resolve_receiver(receiver) do
    case optional_text(receiver) do
      nil -> {:error, :empty_receiver}
      receiver -> normalize_receiver(receiver)
    end
  end

  def obligation_metrics(staker_addresses) do
    with {:ok, cfg} <- config(),
         {:ok, addresses} <- normalize_address_list(staker_addresses) do
      exact_total_accrued_obligations =
        Enum.reduce(addresses, 0, fn address, acc ->
          acc +
            call_uint(
              cfg.chain_id,
              cfg.contract_address,
              Abi.encode_address_call(:preview_claimable_regent, address)
            )
        end)

      materialized_outstanding =
        call_uint(
          cfg.chain_id,
          cfg.contract_address,
          Abi.encode_call(:unclaimed_regent_liability)
        )

      available_reward_inventory =
        call_uint(
          cfg.chain_id,
          cfg.contract_address,
          Abi.encode_call(:available_regent_reward_inventory)
        )

      total_claimed_so_far =
        call_uint(cfg.chain_id, cfg.contract_address, Abi.encode_call(:total_claimed_regent))

      {:ok,
       %{
         staker_count: length(addresses),
         exact_total_accrued_obligations_raw: exact_total_accrued_obligations,
         exact_total_accrued_obligations:
           format_units(exact_total_accrued_obligations, @token_decimals),
         materialized_outstanding_raw: materialized_outstanding,
         materialized_outstanding: format_units(materialized_outstanding, @token_decimals),
         available_reward_inventory_raw: available_reward_inventory,
         available_reward_inventory: format_units(available_reward_inventory, @token_decimals),
         total_claimed_so_far_raw: total_claimed_so_far,
         total_claimed_so_far: format_units(total_claimed_so_far, @token_decimals),
         accrued_but_unsynced_raw:
           positive_difference(exact_total_accrued_obligations, materialized_outstanding),
         accrued_but_unsynced:
           format_units(
             positive_difference(exact_total_accrued_obligations, materialized_outstanding),
             @token_decimals
           ),
         funding_gap_raw:
           positive_difference(exact_total_accrued_obligations, available_reward_inventory),
         funding_gap:
           format_units(
             positive_difference(exact_total_accrued_obligations, available_reward_inventory),
             @token_decimals
           )
       }}
    end
  end

  def stake(attrs, current_human) do
    with {:ok, cfg} <- config(),
         {:ok, wallet_address} <- required_wallet(current_human),
         {:ok, receiver} <- optional_receiver(attrs, wallet_address),
         {:ok, amount} <- parse_amount(Map.get(attrs, "amount"), @token_decimals) do
      stake_token =
        call_address(cfg.chain_id, cfg.contract_address, Abi.encode_call(:stake_token))

      {:ok,
       %{
         staking: compact_state(cfg, wallet_address),
         prepared:
           prepare_wallet_payload!(
             cfg,
             "stake",
             wallet_address,
             chain_id: cfg.chain_id,
             to: cfg.contract_address,
             value_hex: "0x0",
             data: Abi.encode_stake(amount, receiver),
             params: %{amount: Integer.to_string(amount), receiver: receiver},
             approval: %{
               token: stake_token,
               spender: cfg.contract_address,
               amount: Integer.to_string(amount),
               data: Abi.encode_approve(cfg.contract_address, amount)
             }
           )
       }}
    end
  end

  def unstake(attrs, current_human) do
    with {:ok, cfg} <- config(),
         {:ok, wallet_address} <- required_wallet(current_human),
         {:ok, amount} <- parse_amount(Map.get(attrs, "amount"), @token_decimals) do
      {:ok,
       %{
         staking: compact_state(cfg, wallet_address),
         prepared:
           prepare_wallet_payload!(
             cfg,
             "unstake",
             wallet_address,
             chain_id: cfg.chain_id,
             to: cfg.contract_address,
             value_hex: "0x0",
             data: Abi.encode_unstake(amount, wallet_address),
             params: %{amount: Integer.to_string(amount)}
           )
       }}
    end
  end

  def claim_usdc(_attrs, current_human) do
    with {:ok, cfg} <- config(),
         {:ok, wallet_address} <- required_wallet(current_human) do
      {:ok,
       %{
         staking: compact_state(cfg, wallet_address),
         prepared:
           prepare_wallet_payload!(
             cfg,
             "claim_usdc",
             wallet_address,
             chain_id: cfg.chain_id,
             to: cfg.contract_address,
             value_hex: "0x0",
             data: Abi.encode_claim_usdc(wallet_address)
           )
       }}
    end
  end

  def claim_regent(_attrs, current_human) do
    with {:ok, cfg} <- config(),
         {:ok, wallet_address} <- required_wallet(current_human) do
      {:ok,
       %{
         staking: compact_state(cfg, wallet_address),
         prepared:
           prepare_wallet_payload!(
             cfg,
             "claim_regent",
             wallet_address,
             chain_id: cfg.chain_id,
             to: cfg.contract_address,
             value_hex: "0x0",
             data: Abi.encode_claim_regent(wallet_address)
           )
       }}
    end
  end

  def claim_and_restake_regent(_attrs, current_human) do
    with {:ok, cfg} <- config(),
         {:ok, wallet_address} <- required_wallet(current_human) do
      {:ok,
       %{
         staking: compact_state(cfg, wallet_address),
         prepared:
           prepare_wallet_payload!(
             cfg,
             "claim_and_restake_regent",
             wallet_address,
             chain_id: cfg.chain_id,
             to: cfg.contract_address,
             value_hex: "0x0",
             data: Abi.encode_claim_and_restake_regent()
           )
       }}
    end
  end

  def prepare_deposit_usdc(attrs, operator_wallet_address) do
    with {:ok, cfg} <- config(),
         {:ok, expected_signer} <- normalize_required_address(operator_wallet_address),
         {:ok, amount} <- parse_amount(Map.get(attrs, "amount"), @usdc_decimals),
         {:ok, source_tag} <- bytes32_param(Map.get(attrs, "source_tag"), :source_tag_required),
         {:ok, source_ref} <- bytes32_param(Map.get(attrs, "source_ref"), :source_ref_required) do
      {:ok,
       %{
         prepared:
           prepare_payload(
             cfg,
             "deposit_usdc",
             cfg.contract_address,
             Abi.encode_deposit_usdc(amount, source_tag, source_ref),
             %{
               amount: Integer.to_string(amount),
               source_tag: source_tag,
               source_ref: source_ref
             },
             expected_signer
           )
       }}
    end
  end

  def prepare_withdraw_treasury(attrs, operator_wallet_address) do
    with {:ok, cfg} <- config(),
         {:ok, expected_signer} <- normalize_required_address(operator_wallet_address),
         treasury_recipient <-
           call_address(cfg.chain_id, cfg.contract_address, Abi.encode_call(:treasury_recipient)),
         {:ok, amount} <- parse_amount(Map.get(attrs, "amount"), @usdc_decimals),
         {:ok, recipient} <-
           normalize_required_address(Map.get(attrs, "recipient") || treasury_recipient) do
      {:ok,
       %{
         prepared:
           prepare_payload(
             cfg,
             "withdraw_treasury",
             cfg.contract_address,
             Abi.encode_withdraw_treasury_residual(amount, recipient),
             %{amount: Integer.to_string(amount), recipient: recipient},
             expected_signer
           )
       }}
    end
  end

  defp load_state(cfg, wallet_address) do
    owner = call_address(cfg.chain_id, cfg.contract_address, Abi.encode_call(:owner))
    stake_token = call_address(cfg.chain_id, cfg.contract_address, Abi.encode_call(:stake_token))
    usdc = call_address(cfg.chain_id, cfg.contract_address, Abi.encode_call(:usdc))

    treasury_recipient =
      call_address(cfg.chain_id, cfg.contract_address, Abi.encode_call(:treasury_recipient))

    revenue_share_supply_denominator =
      call_uint(
        cfg.chain_id,
        cfg.contract_address,
        Abi.encode_call(:revenue_share_supply_denominator)
      )

    paused = call_bool(cfg.chain_id, cfg.contract_address, Abi.encode_call(:paused))
    total_staked = call_uint(cfg.chain_id, cfg.contract_address, Abi.encode_call(:total_staked))

    treasury_residual_usdc =
      call_uint(cfg.chain_id, cfg.contract_address, Abi.encode_call(:treasury_residual_usdc))

    total_usdc_received =
      call_uint(
        cfg.chain_id,
        cfg.contract_address,
        Abi.encode_call(:total_usdc_received)
      )

    direct_deposit_usdc =
      call_uint(
        cfg.chain_id,
        cfg.contract_address,
        Abi.encode_call(:direct_deposit_usdc)
      )

    materialized_outstanding =
      call_uint(
        cfg.chain_id,
        cfg.contract_address,
        Abi.encode_call(:unclaimed_regent_liability)
      )

    available_reward_inventory =
      call_uint(
        cfg.chain_id,
        cfg.contract_address,
        Abi.encode_call(:available_regent_reward_inventory)
      )

    total_claimed_so_far =
      call_uint(cfg.chain_id, cfg.contract_address, Abi.encode_call(:total_claimed_regent))

    wallet_stake_balance_raw =
      wallet_address &&
        call_uint(
          cfg.chain_id,
          cfg.contract_address,
          Abi.encode_address_call(:staked_balance, wallet_address)
        )

    wallet_claimable_usdc_raw =
      wallet_address &&
        call_uint(
          cfg.chain_id,
          cfg.contract_address,
          Abi.encode_address_call(:preview_claimable_usdc, wallet_address)
        )

    wallet_claimable_regent_raw =
      wallet_address &&
        call_uint(
          cfg.chain_id,
          cfg.contract_address,
          Abi.encode_address_call(:preview_claimable_regent, wallet_address)
        )

    wallet_funded_claimable_regent_raw =
      wallet_address &&
        call_uint(
          cfg.chain_id,
          cfg.contract_address,
          Abi.encode_address_call(:preview_funded_claimable_regent, wallet_address)
        )

    wallet_token_balance_raw =
      wallet_address &&
        call_uint(cfg.chain_id, stake_token, Abi.encode_address_call(:balance_of, wallet_address))

    {:ok,
     %{
       chain_id: cfg.chain_id,
       chain_label: cfg.chain_label,
       contract_address: cfg.contract_address,
       owner_address: owner,
       stake_token_address: stake_token,
       usdc_address: usdc,
       treasury_recipient: treasury_recipient,
       revenue_share_supply_denominator_raw: revenue_share_supply_denominator,
       revenue_share_supply_denominator:
         format_units(revenue_share_supply_denominator, @token_decimals),
       paused: paused,
       total_staked_raw: total_staked,
       total_staked: format_units(total_staked, @token_decimals),
       total_usdc_received_raw: total_usdc_received,
       total_usdc_received: format_units(total_usdc_received, @usdc_decimals),
       direct_deposit_usdc_raw: direct_deposit_usdc,
       direct_deposit_usdc: format_units(direct_deposit_usdc, @usdc_decimals),
       treasury_residual_usdc_raw: treasury_residual_usdc,
       treasury_residual_usdc: format_units(treasury_residual_usdc, @usdc_decimals),
       materialized_outstanding_raw: materialized_outstanding,
       materialized_outstanding: format_units(materialized_outstanding, @token_decimals),
       available_reward_inventory_raw: available_reward_inventory,
       available_reward_inventory: format_units(available_reward_inventory, @token_decimals),
       total_claimed_so_far_raw: total_claimed_so_far,
       total_claimed_so_far: format_units(total_claimed_so_far, @token_decimals),
       wallet_address: wallet_address,
       wallet_stake_balance_raw: wallet_stake_balance_raw,
       wallet_stake_balance:
         wallet_address && format_units(wallet_stake_balance_raw, @token_decimals),
       wallet_token_balance_raw: wallet_token_balance_raw,
       wallet_token_balance:
         wallet_address && format_units(wallet_token_balance_raw, @token_decimals),
       wallet_claimable_usdc_raw: wallet_claimable_usdc_raw,
       wallet_claimable_usdc:
         wallet_address && format_units(wallet_claimable_usdc_raw, @usdc_decimals),
       wallet_claimable_regent_raw: wallet_claimable_regent_raw,
       wallet_claimable_regent:
         wallet_address && format_units(wallet_claimable_regent_raw, @token_decimals),
       wallet_funded_claimable_regent_raw: wallet_funded_claimable_regent_raw,
       wallet_funded_claimable_regent:
         wallet_address && format_units(wallet_funded_claimable_regent_raw, @token_decimals)
     }}
  end

  defp compact_state(cfg, wallet_address) do
    %{
      chain_id: cfg.chain_id,
      chain_label: cfg.chain_label,
      contract_address: cfg.contract_address,
      wallet_address: wallet_address
    }
  end

  defp prepare_payload(cfg, action, target, calldata, params, expected_signer) do
    {:ok, prepared} =
      ActionParams.prepare_tx(
        cfg.chain_id,
        target,
        calldata,
        "regent_staking",
        action,
        params,
        expected_signer: expected_signer
      )

    prepared
  end

  defp config do
    with contract_address when is_binary(contract_address) <-
           InfrastructureConfig.regent_staking_address(:contract_address),
         {:ok, _rpc_url} <- InfrastructureConfig.regent_staking_rpc_url() do
      cfg = InfrastructureConfig.regent_staking()

      {:ok,
       %{
         chain_id: Keyword.get(cfg, :chain_id, @base_chain_id),
         chain_label: Keyword.get(cfg, :chain_label, @base_chain_label),
         contract_address: contract_address
       }}
    else
      _ -> {:error, :unconfigured}
    end
  end

  defp call_uint(chain_id, to, data) do
    {:ok, result} = Rpc.eth_call(chain_id, to, data, source: :regent_staking)
    Abi.decode_uint256(result)
  end

  defp call_address(chain_id, to, data) do
    {:ok, result} = Rpc.eth_call(chain_id, to, data, source: :regent_staking)
    Abi.decode_address(result)
  end

  defp call_bool(chain_id, to, data) do
    {:ok, result} = Rpc.eth_call(chain_id, to, data, source: :regent_staking)
    Abi.decode_bool(result)
  end

  defp required_wallet(%HumanUser{} = human) do
    case primary_wallet_address(human) do
      nil -> {:error, :unauthorized}
      address -> {:ok, address}
    end
  end

  defp required_wallet(%{"wallet_address" => wallet_address}) do
    normalize_required_address(wallet_address)
  end

  defp required_wallet(_actor), do: {:error, :unauthorized}

  defp primary_wallet_address(%HumanUser{} = human) do
    [human.wallet_address | List.wrap(human.wallet_addresses)]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> normalize_address()
  end

  defp primary_wallet_address(%{"wallet_address" => wallet_address}) do
    normalize_address(wallet_address)
  end

  defp primary_wallet_address(_human), do: nil

  defp prepare_wallet_payload!(cfg, action, wallet_address, request) do
    request = Map.new(request)

    params =
      request
      |> Map.get(:params, %{})
      |> Map.merge(%{contract_address: cfg.contract_address})

    {:ok, prepared} =
      ActionParams.prepare_tx_request(
        request,
        "regent_staking",
        action,
        params,
        expected_signer: wallet_address
      )

    put_optional_approval(prepared, Map.get(request, :approval))
  end

  defp put_optional_approval(prepared, nil), do: prepared

  defp put_optional_approval(prepared, approval) do
    prepared
    |> Map.put(:approval, approval)
    |> put_in([:wallet_action, :approval], approval)
  end

  defp parse_amount(value, decimals) when is_binary(value) do
    trimmed = String.trim(value)

    with {decimal, ""} <- Decimal.parse(trimmed),
         true <- Decimal.compare(decimal, 0) == :gt || {:error, :amount_required},
         scaled <- Decimal.mult(decimal, Decimal.new(integer_pow10(decimals))),
         true <-
           Decimal.compare(scaled, Decimal.round(scaled, 0)) == :eq ||
             {:error, :invalid_amount_precision} do
      {:ok, Decimal.to_integer(scaled)}
    else
      :error -> {:error, :amount_required}
      {:error, _} = error -> error
      _ -> {:error, :amount_required}
    end
  end

  defp parse_amount(_value, _decimals), do: {:error, :amount_required}

  defp bytes32_param(value, missing_error) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, missing_error}

      Regex.match?(~r/^0x[0-9a-fA-F]{64}$/, trimmed) ->
        {:ok, String.downcase(trimmed)}

      byte_size(trimmed) <= 32 ->
        encoded =
          trimmed
          |> Base.encode16(case: :lower)
          |> String.pad_trailing(64, "0")

        {:ok, "0x" <> encoded}

      true ->
        {:error, :invalid_source_ref}
    end
  end

  defp bytes32_param(_value, missing_error), do: {:error, missing_error}

  defp optional_receiver(attrs, default_receiver) do
    case optional_text(Map.get(attrs, "receiver")) do
      nil -> {:ok, default_receiver}
      receiver -> resolve_receiver(receiver)
    end
  end

  defp normalize_receiver(receiver) do
    cond do
      String.starts_with?(String.downcase(receiver), "0x") ->
        normalize_required_address(receiver)

      String.contains?(receiver, ".") ->
        resolve_ens_receiver(receiver)

      true ->
        {:error, :invalid_address}
    end
  end

  defp optional_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp optional_text(_value), do: nil

  defp normalize_required_address(value) do
    case Evm.normalize_address(value) do
      nil -> {:error, :invalid_address}
      @zero_address -> {:error, :invalid_address}
      address -> {:ok, address}
    end
  end

  defp resolve_ens_receiver(receiver) do
    case AgentEns.Normalize.normalize(receiver) do
      {:ok, normalized_name} ->
        resolve_normalized_ens_receiver(normalized_name)

      {:error, _reason} ->
        {:error, :invalid_ens_name}
    end
  end

  defp resolve_normalized_ens_receiver(normalized_name) do
    with {:ok, rpc_url} <- ethereum_rpc_url(),
         {:ok, details} <-
           ens_module().read_name(%{
             ens_name: normalized_name,
             chain_id: @ethereum_mainnet_chain_id,
             rpc_url: rpc_url,
             include_address?: true,
             include_contenthash?: false
           }),
         {:ok, eth_address} <- ens_eth_address(details),
         {:ok, receiver} <- normalize_required_address(eth_address) do
      {:ok, receiver}
    else
      {:error, :ens_unconfigured} -> {:error, :ens_unconfigured}
      {:error, :ens_address_missing} -> {:error, :ens_address_missing}
      {:error, :invalid_address} -> {:error, :ens_address_missing}
      {:error, _reason} -> {:error, :ens_unavailable}
    end
  end

  defp ens_eth_address(%{eth_address: eth_address}) when is_binary(eth_address),
    do: {:ok, eth_address}

  defp ens_eth_address(%{"eth_address" => eth_address}) when is_binary(eth_address),
    do: {:ok, eth_address}

  defp ens_eth_address(_details), do: {:error, :ens_address_missing}

  defp ethereum_rpc_url do
    case InfrastructureConfig.regent_staking_text(:ethereum_rpc_url) do
      nil -> {:error, :ens_unconfigured}
      rpc_url -> {:ok, rpc_url}
    end
  end

  defp ens_module do
    :autolaunch
    |> Application.get_env(:regent_staking, [])
    |> Keyword.get(:ens_module, AgentEns)
  end

  defp normalize_address_list(values) when is_list(values) do
    Evm.normalize_address_list(values)
  end

  defp normalize_address_list(_values), do: {:error, :invalid_address}

  defp normalize_address(value), do: Evm.normalize_address(value)

  defp format_units(value, decimals) when is_integer(value) do
    value
    |> Decimal.new()
    |> Decimal.div(Decimal.new(integer_pow10(decimals)))
    |> Decimal.normalize()
    |> Decimal.to_string(:normal)
  end

  defp format_units(nil, _decimals), do: nil

  defp integer_pow10(exponent) when exponent >= 0, do: Integer.pow(10, exponent)

  defp positive_difference(left, right) when left > right, do: left - right
  defp positive_difference(_left, _right), do: 0
end
