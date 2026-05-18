defmodule Autolaunch.Swaps do
  @moduledoc false

  alias Autolaunch.{BaseChain, Evm, Tokens}
  alias Autolaunch.Launch.Core, as: LaunchCore

  @usdc_decimals 6
  @agent_token_decimals 18
  @max_slippage_bps 500
  @approve_selector "0x095ea7b3"
  @min_swap_calldata_bytes 4
  @decimal_amount_pattern ~r/\A[0-9]+(\.[0-9]+)?\z/

  def available? do
    cfg = config()

    base_available?(cfg) and
      Enum.any?(BaseChain.supported_chain_ids(), &chain_configured?(cfg, &1))
  end

  def available?(chain_id) do
    cfg = config()

    case BaseChain.normalize_chain_id(chain_id) do
      chain_id when is_integer(chain_id) ->
        base_available?(cfg) and chain_configured?(cfg, chain_id)

      _ ->
        false
    end
  end

  def quote(attrs, current_human) do
    with {:ok, request} <- build_request(attrs, current_human),
         {:ok, quote} <- quote_from_uniswap(request) do
      {:ok, %{quote: public_quote(request, quote)}}
    end
  end

  def prepare(attrs, current_human) do
    with {:ok, request} <- build_request(attrs, current_human),
         {:ok, quoted} <- quote_from_uniswap(request),
         {:ok, swap} <- client().swap(swap_body(quoted), client_opts()),
         {:ok, tx} <- swap_transaction(swap),
         {:ok, wallet_action} <- wallet_action(request, tx),
         quote <- public_quote(request, quoted) do
      {:ok, %{swap: %{wallet_action: wallet_action, quote: quote}}}
    end
  end

  defp build_request(_attrs, nil), do: {:error, :unauthorized}

  defp build_request(attrs, current_human) when is_map(attrs) do
    with {:ok, chain_id} <- chain_id(Map.get(attrs, "chain_id")),
         :ok <- ensure_available(chain_id),
         {:ok, token_address} <- required_address(Map.get(attrs, "token_address")),
         {:ok, _token} <- Tokens.get_graduated_token(chain_id, token_address),
         {:ok, side} <- side(Map.get(attrs, "side")),
         {:ok, swapper} <- required_address(Map.get(attrs, "swapper")),
         :ok <- ensure_wallet(current_human, swapper),
         {:ok, amount_raw} <- amount_raw(Map.get(attrs, "amount"), decimals_for(side)),
         {:ok, slippage_bps} <- slippage_bps(Map.get(attrs, "slippage_bps")),
         {:ok, usdc} <- BaseChain.canonical_usdc_address(chain_id) do
      {token_in, token_out} =
        case side do
          "buy" -> {usdc, token_address}
          "sell" -> {token_address, usdc}
        end

      {:ok,
       %{
         side: side,
         chain_id: chain_id,
         token_address: token_address,
         token_in: token_in,
         token_out: token_out,
         amount_raw: amount_raw,
         slippage_bps: slippage_bps,
         swapper: swapper
       }}
    end
  end

  defp quote_from_uniswap(request) do
    quote_body = %{
      type: "EXACT_INPUT",
      tokenInChainId: request.chain_id,
      tokenOutChainId: request.chain_id,
      tokenIn: request.token_in,
      tokenOut: request.token_out,
      amount: request.amount_raw,
      swapper: request.swapper,
      slippageTolerance: request.slippage_bps / 100,
      routingPreference: "BEST_PRICE",
      protocols: ["V4"],
      urgency: "normal",
      generatePermitAsTransaction: false
    }

    with {:ok, approval} <- check_approval(request),
         {:ok, quote_response} <- client().quote(quote_body, client_opts()),
         :ok <- ensure_classic_v4_quote(quote_response),
         :ok <- ensure_price_impact(quote_response),
         quote <-
           quote_response |> Map.put("__approval", approval) |> Map.put("__body", quote_body) do
      {:ok, quote}
    end
  end

  defp check_approval(request) do
    body = %{
      chainId: request.chain_id,
      walletAddress: request.swapper,
      token: request.token_in,
      amount: request.amount_raw,
      includeGasInfo: true,
      urgency: "normal",
      tokenOut: request.token_out,
      tokenOutChainId: request.chain_id
    }

    with {:ok, response} <- client().check_approval(body, client_opts()),
         {:ok, approval} <- approval_action(request, response["approval"]) do
      {:ok, approval}
    end
  end

  defp swap_body(quoted) do
    %{
      quote: Map.fetch!(quoted, "quote"),
      simulateTransaction: true,
      refreshGasPrice: true,
      safetyMode: "SAFE",
      urgency: "normal"
    }
  end

  defp public_quote(request, quoted) do
    quote = Map.fetch!(quoted, "quote")
    output = Map.get(quote, "output", %{})

    %{
      side: request.side,
      chain_id: request.chain_id,
      token_address: request.token_address,
      token_in: request.token_in,
      token_out: request.token_out,
      amount_in_raw: request.amount_raw,
      amount_out_raw: value_to_string(Map.get(output, "amount")),
      minimum_amount_out_raw: minimum_amount_out(quote),
      route_label: route_label(quote),
      approval: Map.get(quoted, "__approval"),
      price_impact_percent: value_to_string(Map.get(quote, "priceImpact")),
      gas_fee: value_to_string(Map.get(quote, "gasFee"))
    }
  end

  defp wallet_action(request, tx) do
    to = Evm.normalize_address(Map.fetch!(tx, "to"))
    value_hex = zero_value_hex!(Map.get(tx, "value") || "0x0")
    data = Map.fetch!(tx, "data")
    idempotency_key = swap_idempotency_key(request, to, value_hex, data)

    :ok = ensure_transaction_chain(request.chain_id, tx)
    :ok = ensure_allowed_transaction_target(request.chain_id, to)
    :ok = ensure_hex_data(data, @min_swap_calldata_bytes)

    action = %{
      action_id: "uniswap_v4_swap:#{digest_part(idempotency_key)}",
      resource: "swap",
      resource_id: "#{request.side}:#{request.token_address}",
      action: request.side,
      chain_id: request.chain_id,
      to: to,
      value_hex: value_hex,
      data: data,
      expected_signer: request.swapper,
      expires_at: DateTime.utc_now() |> DateTime.add(180, :second) |> DateTime.to_iso8601(),
      idempotency_key: idempotency_key,
      simulation: %{required: true, status: "passed", block_number: nil},
      risk_copy: "Swaps Base USDC and this agent token through Uniswap v4."
    }

    {:ok, LaunchCore.serialize_wallet_action(action)}
  rescue
    _ -> {:error, :invalid_swap_transaction}
  end

  defp swap_transaction(%{"swap" => %{"to" => to, "data" => data} = tx})
       when is_binary(to) and is_binary(data),
       do: {:ok, tx}

  defp swap_transaction(%{"swap" => %{"transaction" => tx}}), do: swap_transaction(tx)
  defp swap_transaction(%{"transaction" => tx}), do: swap_transaction(tx)

  defp swap_transaction(%{"to" => to, "data" => data} = tx)
       when is_binary(to) and is_binary(data),
       do: {:ok, tx}

  defp swap_transaction(_response), do: {:error, :invalid_swap_transaction}

  defp ensure_classic_v4_quote(%{"routing" => "CLASSIC", "quote" => %{"route" => route}}) do
    if route_has_only_v4?(route), do: :ok, else: {:error, :unsupported_route}
  end

  defp ensure_classic_v4_quote(_response), do: {:error, :unsupported_route}

  defp route_has_only_v4?(route) when is_list(route) do
    steps = List.flatten(route)

    steps != [] and
      Enum.all?(steps, fn step -> is_map(step) and Map.get(step, "type") == "v4-pool" end)
  end

  defp route_has_only_v4?(_route), do: false

  defp approval_action(_request, nil), do: {:ok, nil}

  defp approval_action(request, %{"to" => to, "data" => data} = approval)
       when is_binary(to) and is_binary(data) do
    token = Evm.normalize_address(to)
    value = Map.get(approval, "value", "0x0")
    value_hex = zero_value_hex!(value || "0x0")
    :ok = ensure_approval_target(request, token, data)
    spender = approval_spender!(data)
    :ok = ensure_approval_amount(request, data)
    :ok = ensure_allowed_approval_spender(request.chain_id, spender)

    action = %{
      action_id:
        "uniswap_v4_approval:#{digest_part("#{request.chain_id}:#{token}:#{spender}:#{request.amount_raw}")}",
      resource: "swap",
      resource_id: "#{request.side}:#{request.token_address}:approval",
      action: "approve",
      chain_id: request.chain_id,
      to: token,
      value_hex: value_hex,
      data: data,
      expected_signer: request.swapper,
      expires_at: DateTime.utc_now() |> DateTime.add(180, :second) |> DateTime.to_iso8601(),
      idempotency_key:
        "swap-approval:#{request.chain_id}:#{request.side}:#{request.token_in}:#{spender}:#{request.amount_raw}:#{request.swapper}",
      simulation: %{required: false, status: "not_required", block_number: nil},
      risk_copy: "Approves this swap spend before the wallet trade."
    }

    {:ok, LaunchCore.serialize_wallet_action(action)}
  rescue
    _ -> {:error, :invalid_approval_transaction}
  end

  defp approval_action(_request, _approval), do: {:error, :invalid_approval_transaction}

  defp ensure_transaction_chain(chain_id, tx) do
    tx_chain_id = Map.get(tx, "chainId") || Map.get(tx, "chain_id")

    case tx_chain_id do
      nil ->
        :ok

      ^chain_id ->
        :ok

      value when is_binary(value) ->
        if BaseChain.normalize_chain_id(value) == chain_id, do: :ok, else: raise(ArgumentError)

      _ ->
        raise ArgumentError
    end
  end

  defp ensure_allowed_transaction_target(chain_id, to) do
    if to in configured_addresses(:allowed_transaction_targets, chain_id),
      do: :ok,
      else: raise(ArgumentError)
  end

  defp ensure_allowed_approval_spender(chain_id, spender) do
    if spender in configured_addresses(:allowed_approval_spenders, chain_id),
      do: :ok,
      else: raise(ArgumentError)
  end

  defp configured_addresses(key, chain_id), do: configured_addresses(config(), key, chain_id)

  defp configured_addresses(cfg, key, chain_id) do
    cfg
    |> Keyword.get(key, %{})
    |> Map.get(chain_id, [])
    |> Enum.map(&Evm.normalize_address/1)
    |> Enum.reject(&is_nil/1)
  end

  defp base_available?(cfg) do
    Keyword.get(cfg, :enabled, false) == true and
      not blank?(Keyword.get(cfg, :uniswap_api_key, ""))
  end

  defp chain_configured?(cfg, chain_id) do
    configured_addresses(cfg, :allowed_transaction_targets, chain_id) != [] and
      configured_addresses(cfg, :allowed_approval_spenders, chain_id) != []
  end

  defp ensure_approval_target(request, token, data) do
    cond do
      token != request.token_in ->
        raise ArgumentError

      not String.starts_with?(String.downcase(data), @approve_selector) ->
        raise ArgumentError

      byte_size(data) != 138 ->
        raise ArgumentError

      true ->
        ensure_hex_data(data, 68)
    end
  end

  defp approval_spender!(data) do
    data
    |> String.slice(10, 64)
    |> String.slice(24, 40)
    |> then(&("0x" <> &1))
    |> Evm.normalize_address()
    |> case do
      "0x" <> _ = address -> address
      _ -> raise ArgumentError
    end
  end

  defp ensure_approval_amount(request, data) do
    approval_amount =
      data
      |> String.slice(74, 64)
      |> String.to_integer(16)
      |> Integer.to_string()

    if approval_amount == request.amount_raw,
      do: :ok,
      else: raise(ArgumentError)
  end

  defp ensure_hex_data("0x" <> hex, min_bytes) do
    if byte_size(hex) >= min_bytes * 2 and rem(byte_size(hex), 2) == 0 and
         Regex.match?(~r/\A[0-9a-fA-F]*\z/, hex) do
      :ok
    else
      raise ArgumentError
    end
  end

  defp ensure_hex_data(_data, _min_bytes), do: raise(ArgumentError)

  defp hex_quantity!(value) when is_integer(value) and value >= 0,
    do: "0x" <> Integer.to_string(value, 16)

  defp hex_quantity!(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      Regex.match?(~r/\A0x[0-9a-fA-F]+\z/, trimmed) ->
        parsed =
          trimmed
          |> String.trim_leading("0x")
          |> String.to_integer(16)

        "0x" <> Integer.to_string(parsed, 16)

      Regex.match?(~r/\A[0-9]+\z/, trimmed) ->
        "0x" <> (trimmed |> String.to_integer() |> Integer.to_string(16))

      true ->
        raise ArgumentError
    end
  end

  defp hex_quantity!(_value), do: raise(ArgumentError)

  defp zero_value_hex!(value) do
    case hex_quantity!(value) do
      "0x0" -> "0x0"
      _nonzero -> raise ArgumentError
    end
  end

  defp ensure_price_impact(%{"quote" => quote}) do
    with {:ok, impact} <- decimal_value(Map.get(quote, "priceImpact")),
         {:ok, max_impact} <- max_price_impact_percent() do
      if Decimal.compare(Decimal.abs(impact), max_impact) in [:lt, :eq],
        do: :ok,
        else: {:error, :price_impact_too_high}
    else
      _ -> {:error, :price_impact_unavailable}
    end
  end

  defp ensure_price_impact(_response), do: {:error, :price_impact_unavailable}

  defp decimal_value(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal_value(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  defp decimal_value(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> finite_decimal(decimal)
      _ -> {:error, :invalid_decimal}
    end
  end

  defp decimal_value(_value), do: {:error, :invalid_decimal}

  defp finite_decimal(%Decimal{} = decimal) do
    if Decimal.nan?(decimal) or Decimal.inf?(decimal),
      do: {:error, :invalid_decimal},
      else: {:ok, decimal}
  end

  defp max_price_impact_percent do
    config()
    |> Keyword.get(:max_price_impact_percent, "5")
    |> decimal_value()
  end

  defp swap_idempotency_key(request, to, value_hex, data) do
    [
      "swap",
      request.chain_id,
      request.side,
      request.token_in,
      request.token_out,
      request.amount_raw,
      request.slippage_bps,
      request.swapper,
      to,
      value_hex,
      digest_part(data)
    ]
    |> Enum.join(":")
  end

  defp digest_part(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp minimum_amount_out(%{"aggregatedOutputs" => [%{"minAmount" => min_amount} | _]}),
    do: value_to_string(min_amount)

  defp minimum_amount_out(%{"output" => %{"amount" => amount}}), do: value_to_string(amount)
  defp minimum_amount_out(_quote), do: "0"

  defp route_label(%{"routeString" => route}) when is_binary(route), do: route
  defp route_label(_quote), do: "Uniswap v4"

  defp value_to_string(value) when is_integer(value), do: Integer.to_string(value)

  defp value_to_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 4)

  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(_value), do: nil

  defp amount_raw(value, decimals) when is_binary(value) do
    with {:ok, decimal} <- decimal_string(value),
         :gt <- Decimal.compare(decimal, Decimal.new(0)),
         scaled <- Decimal.mult(decimal, decimal_unit(decimals)),
         rounded <- Decimal.round(scaled, 0, :down),
         true <- Decimal.equal?(scaled, rounded) do
      {:ok, Decimal.to_integer(rounded) |> Integer.to_string()}
    else
      _ -> {:error, :invalid_amount}
    end
  end

  defp amount_raw(_value, _decimals), do: {:error, :invalid_amount}

  defp decimal_string(value) do
    trimmed = String.trim(value)

    if Regex.match?(@decimal_amount_pattern, trimmed) do
      case Decimal.parse(trimmed) do
        {decimal, ""} -> {:ok, decimal}
        _ -> {:error, :invalid_amount}
      end
    else
      {:error, :invalid_amount}
    end
  end

  defp decimals_for("buy"), do: @usdc_decimals
  defp decimals_for("sell"), do: @agent_token_decimals

  defp decimal_unit(decimals), do: Decimal.new("1" <> String.duplicate("0", decimals))

  defp chain_id(chain_id) when chain_id in [8_453, 84_532], do: {:ok, chain_id}
  defp chain_id(_value), do: {:error, :unsupported_chain}

  defp required_address(value) do
    case Evm.normalize_address(value) do
      "0x" <> _ = address -> {:ok, address}
      _ -> {:error, :invalid_address}
    end
  end

  defp side(side) when side in ["buy", "sell"], do: {:ok, side}
  defp side(_side), do: {:error, :invalid_side}

  defp slippage_bps(value) when is_integer(value) and value in 1..@max_slippage_bps,
    do: {:ok, value}

  defp slippage_bps(_value), do: {:error, :invalid_slippage}

  defp ensure_wallet(current_human, swapper) do
    wallets =
      current_human
      |> LaunchCore.linked_wallet_addresses()
      |> Enum.map(&Evm.normalize_address/1)

    if swapper in wallets, do: :ok, else: {:error, :wallet_mismatch}
  end

  defp ensure_available(chain_id) do
    cfg = config()

    cond do
      not Keyword.get(cfg, :enabled, false) -> {:error, :swaps_disabled}
      blank?(Keyword.get(cfg, :uniswap_api_key, "")) -> {:error, :swaps_unconfigured}
      not chain_configured?(cfg, chain_id) -> {:error, :swaps_unconfigured}
      true -> :ok
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp client_opts do
    cfg = config()

    [
      api_key: Keyword.get(cfg, :uniswap_api_key, ""),
      base_url: Keyword.fetch!(cfg, :uniswap_api_base_url),
      http_client: Keyword.get(cfg, :http_client, Req)
    ]
  end

  defp client do
    Keyword.get(config(), :client, Autolaunch.Swaps.UniswapClient)
  end

  defp config, do: Application.get_env(:autolaunch, :swaps, [])
end
