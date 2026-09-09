defmodule Autolaunch.LabBidChainClient do
  @moduledoc false

  @behaviour Autolaunch.ChainClient

  alias Autolaunch.Chain.{Abi, Address, Envelope}
  alias Autolaunch.{Lab, LabAbi, LabRpc}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi

  @max_tick_walk 256
  @max_uint256 Integer.pow(2, 256) - 1

  # The auction's own `currency()` is the token every balance and allowance is
  # read from: REGENT for an Agent auction, the admitted stock for a Stocks one.
  @impl true
  def snapshot(%{auction: auction, signer: signer, max_price_q96: max_price}) do
    with {:ok, auction} <- Address.normalize(auction),
         {:ok, config, block, opts} <- LabRpc.current([:regent, :permit2]),
         :ok <- LabRpc.ensure_contract(auction, block, opts),
         {:ok, currency} <- call_address(config, auction, "currency()", [], block, opts),
         {:ok, currency_balance} <-
           LabRpc.call_uint(
             config,
             currency,
             "token",
             "balanceOf(address)",
             [signer],
             block,
             opts
           ),
         {:ok, token_allowance} <-
           LabRpc.call_uint(
             config,
             currency,
             "token",
             "allowance(address,address)",
             [signer, Lab.address!(config, :permit2)],
             block,
             opts
           ),
         {:ok, permit2_words} <-
           LabRpc.words(
             config,
             :permit2,
             "allowance(address,address,address)",
             [signer, currency, auction],
             3,
             block,
             opts
           ),
         [permit2_amount, permit2_expiration, _nonce] <- permit2_words,
         {:ok, spacing} <- call_uint(config, auction, "tickSpacing()", [], block, opts),
         {:ok, floor} <- call_uint(config, auction, "floorPrice()", [], block, opts),
         {:ok, [clearing, _raised, _mps_per_price, _mps, _prev, _next]} <-
           call_words(config, auction, "checkpoint()", [], 6, block, opts),
         {:ok, cap} <- call_uint(config, auction, "MAX_BID_PRICE()", [], block, opts),
         limits <- %{
           tick_spacing_q96: spacing,
           floor_price_q96: floor,
           clearing_price_q96: clearing,
           max_bid_price_q96: cap
         },
         {:ok, aligned} <- aligned_price(max_price, limits),
         {:ok, prev_tick_price_q96} <- predecessor(config, auction, aligned, block, opts) do
      {:ok,
       %{
         tick_spacing_q96: spacing,
         floor_price_q96: floor,
         clearing_price_q96: clearing,
         max_bid_price_q96: cap,
         auction: auction,
         currency: currency,
         currency_balance: currency_balance,
         token_allowance: token_allowance,
         permit2_amount: permit2_amount,
         permit2_expiration: permit2_expiration,
         prev_tick_price_q96: prev_tick_price_q96,
         predecessor_source: "bounded local auction tick walk",
         block: block,
         permit2: Lab.address!(config, :permit2),
         lab_binding: Lab.binding(config, [:regent, :permit2])
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @doc """
  The USDC side of a Stocks bid: the wallet's USDC and its allowance to the bid
  adapter, and the admitted route's estimate of the STOCK `usdc_amount` buys.
  """
  def usdc_snapshot(%{stock: stock, signer: signer, usdc_amount: usdc_amount}) do
    with {:ok, config} <- StocksLab.current(),
         opts <- StocksLab.rpc_opts(config),
         {:ok, block} <- Autolaunch.Chain.Rpc.latest_block(opts),
         usdc <- StocksLab.address!(config, :usdc),
         adapter <- StocksLab.address!(config, :bid_adapter),
         launchpad <- StocksLab.address!(config, :launchpad),
         :ok <- LabRpc.ensure_contract(adapter, block, opts),
         {:ok, [admitted, _decimals, route_word]} <-
           Autolaunch.Chain.Rpc.call_words(
             launchpad,
             LabAbi.encode(StocksLab.abi!(config, :launchpad), "stockAdmission(address)", [stock]),
             block,
             3,
             opts
           ),
         true <- admitted != 0,
         {:ok, route} <- Abi.word_address(route_word),
         {:ok, usdc_balance} <-
           Autolaunch.Chain.Rpc.call_uint(
             usdc,
             LabAbi.encode(StocksLab.abi!(config, :erc20), "balanceOf(address)", [signer]),
             block,
             opts
           ),
         {:ok, usdc_allowance} <-
           Autolaunch.Chain.Rpc.call_uint(
             usdc,
             LabAbi.encode(StocksLab.abi!(config, :erc20), "allowance(address,address)", [
               signer,
               adapter
             ]),
             block,
             opts
           ),
         {:ok, stock_quote} <-
           Autolaunch.Chain.Rpc.call_uint(
             route,
             LabAbi.encode(
               StocksLab.abi!(config, :route),
               "quoteExactIn(address,address,uint256)",
               [
                 usdc,
                 stock,
                 usdc_amount
               ]
             ),
             block,
             opts
           ) do
      {:ok,
       %{
         usdc: usdc,
         adapter: adapter,
         route: route,
         usdc_balance: usdc_balance,
         usdc_allowance: usdc_allowance,
         stock_quote: stock_quote,
         block: block
       }}
    else
      false -> {:error, :stock_not_admitted}
      :error -> {:error, :invalid_chain_response}
      {:error, :stocks_lab_disabled} -> {:error, :usdc_bids_unavailable}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @impl true
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, step, hash) do
    with true <-
           Envelope.valid_for_confirmation?(envelope,
             resource: "autolaunch_auction",
             chain_id: Lab.chain_id()
           ),
         true <- Lab.binding_matches?(envelope["metadata"]["lab"], [:regent, :permit2]),
         {:ok, config} <- Lab.current(),
         current <- current_step(envelope, step),
         {:ok, evidence} <- LabRpc.canonical_outcome_evidence(config, envelope, current, hash),
         {:ok, result} <- settled(evidence.outcome, envelope, step, config) do
      {:ok, Map.put(result, :receipt, evidence.receipt)}
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp aligned_price(nil, _limits), do: {:ok, nil}
  defp aligned_price(price, limits), do: Autolaunch.BidPrice.align(price, limits)

  defp predecessor(config, auction, max_price, block, opts) when is_integer(max_price) do
    with {:ok, floor} <- call_uint(config, auction, "floorPrice()", [], block, opts),
         true <- floor < max_price do
      walk_ticks(config, auction, floor, max_price, block, opts, 0)
    else
      false -> {:error, :bid_preparation_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp predecessor(_config, _auction, nil, _block, _opts), do: {:ok, 0}

  defp walk_ticks(_config, _auction, _current, _max_price, _block, _opts, @max_tick_walk),
    do: {:error, :bid_preparation_unavailable}

  defp walk_ticks(config, auction, current, max_price, block, opts, hops) do
    with {:ok, [next, _demand]} <-
           call_words(config, auction, "ticks(uint256)", [current], 2, block, opts) do
      cond do
        next == @max_uint256 -> {:ok, current}
        next >= max_price -> {:ok, current}
        next > current -> walk_ticks(config, auction, next, max_price, block, opts, hops + 1)
        true -> {:error, :bid_preparation_unavailable}
      end
    end
  end

  defp settled(:pending, _envelope, _step, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _config), do: {:ok, %{outcome: :reverted}}

  defp settled({:success, logs}, envelope, :token_approval, config) do
    step = current_step(envelope, :token_approval)
    amount = String.to_integer(step["amount"])
    currency = envelope["arguments"]["currency"]

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         true <-
           Abi.approval_recorded?(
             logs,
             currency,
             envelope["expected_signer"],
             Lab.address!(config, :permit2),
             amount
           ),
         opts <- LabRpc.opts(config),
         {:ok, allowance} <-
           LabRpc.call_uint(
             config,
             currency,
             "token",
             "allowance(address,address)",
             [envelope["expected_signer"], Lab.address!(config, :permit2)],
             block,
             opts
           ) do
      {:ok, %{outcome: if(allowance == amount, do: :confirmed, else: :unverified)}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The exact USDC allowance to the adapter, recorded and standing.
  defp settled({:success, logs}, envelope, :usdc_approval, config) do
    step = current_step(envelope, :usdc_approval)
    amount = String.to_integer(step["amount"])
    usdc = envelope["arguments"]["usdc"]
    adapter = envelope["arguments"]["adapter"]

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         true <- Abi.approval_recorded?(logs, usdc, envelope["expected_signer"], adapter, amount),
         opts <- LabRpc.opts(config),
         {:ok, allowance} <-
           LabRpc.call_uint(
             config,
             usdc,
             "token",
             "allowance(address,address)",
             [envelope["expected_signer"], adapter],
             block,
             opts
           ) do
      {:ok, %{outcome: if(allowance == amount, do: :confirmed, else: :unverified)}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Only the adapter's own `StockBidPlaced` for this auction and this owner
  # confirms a USDC bid; its bid id and committed STOCK are adopted from it.
  defp settled({:success, logs}, envelope, :usdc_bid, config) do
    arguments = envelope["arguments"]

    with {:ok, stocks} <- StocksLab.current(),
         {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, {[auction_word, owner_word, bid_id], [usdc_spent, stock_committed, price]}} <-
           LabAbi.event_words(
             StocksLab.abi!(stocks, :bid_adapter),
             StocksLabAbi.bid_placed_signature(),
             logs,
             arguments["adapter"]
           ),
         {:ok, auction} <- Abi.word_address(auction_word),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(auction, arguments["auction_address"]),
         true <- Address.equal?(owner, envelope["expected_signer"]),
         true <- price == integer(envelope, "max_price_q96"),
         true <- usdc_spent == integer(envelope, "usdc_amount_atomic"),
         opts <- LabRpc.opts(config),
         {:ok, clearing_price} <-
           call_uint(config, arguments["auction_address"], "clearingPrice()", [], block, opts) do
      id = Integer.to_string(bid_id)
      decimals = String.to_integer(arguments["currency_decimals"])

      {:ok,
       %{
         outcome: :confirmed,
         onchain_bid_id: id,
         result: %{
           "onchain_bid_id" => id,
           "amount" => Autolaunch.Chain.Rpc.format_units(stock_committed, decimals),
           "stock_committed_atomic" => Integer.to_string(stock_committed),
           "current_clearing_price" =>
             Autolaunch.Stocks.Amounts.format_cca_price(clearing_price, decimals, 18),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settled({:success, logs}, envelope, :permit2_approval, config) do
    step = current_step(envelope, :permit2_approval)

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         opts <- LabRpc.opts(config),
         {:ok, words} <-
           LabRpc.words(
             config,
             :permit2,
             "allowance(address,address,address)",
             [
               envelope["expected_signer"],
               envelope["arguments"]["currency"],
               envelope["to"]
             ],
             3,
             block,
             opts
           ),
         [amount, expiration, _nonce] <- words do
      expected =
        {String.to_integer(step["amount"]), String.to_integer(step["expiration"])}

      {:ok, %{outcome: if({amount, expiration} == expected, do: :confirmed, else: :unverified)}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  defp settled({:success, logs}, envelope, :bid, config) do
    signature = "BidSubmitted(uint256,address,uint256,uint128)"

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, {[bid_id, owner_word], [price, amount]}} <-
           LabAbi.event_words(Lab.abi!(config, :auction), signature, logs, envelope["to"]),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(owner, envelope["expected_signer"]),
         true <- price == integer(envelope, "max_price_q96"),
         true <- amount == integer(envelope, "amount_atomic"),
         opts <- LabRpc.opts(config),
         {:ok, clearing_price} <-
           call_uint(config, envelope["to"], "clearingPrice()", [], block, opts) do
      id = Integer.to_string(bid_id)
      decimals = String.to_integer(envelope["arguments"]["currency_decimals"])

      {:ok,
       %{
         outcome: :confirmed,
         onchain_bid_id: id,
         result: %{
           "onchain_bid_id" => id,
           "amount" => envelope["arguments"]["amount"],
           "current_clearing_price" =>
             Autolaunch.Stocks.Amounts.format_cca_price(clearing_price, decimals, 18),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_address(config, address, signature, arguments, block, opts) do
    Autolaunch.Chain.Rpc.call_address(
      address,
      LabAbi.encode(Lab.abi!(config, :auction), signature, arguments),
      block,
      opts
    )
  end

  defp call_uint(config, address, signature, arguments, block, opts),
    do: LabRpc.call_uint(config, address, "auction", signature, arguments, block, opts)

  defp call_words(config, address, signature, arguments, count, block, opts),
    do: LabRpc.call_words(config, address, "auction", signature, arguments, count, block, opts)

  defp current_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end

  defp integer(envelope, key), do: envelope["arguments"][key] |> String.to_integer()
end
