defmodule Autolaunch.Robinhood.StockBidChainClient do
  @moduledoc """
  The one chain boundary a USDG bid on a Robinhood memestock auction has: one
  snapshot before review, one read after the hash.

  A bid is funded in USDG, committed in STOCK (the auction's currency), and any
  unspent auction currency comes back as STOCK; the purchased token a winning
  bid claims is the NEW token. `snapshot/1` answers at one pinned block: the
  bid adapter's bindings, the auction's STOCK and its admission record, the
  signer's USDG balance and allowance to the adapter, the admitted route's
  estimate of the STOCK the USDG buys, the auction's price limits, the
  requested maximum aligned to the auction's tick grid, and that tick's
  predecessor. `verify/3` reads the allowance back for the approval step, and
  for the bid step decodes the adapter's `StockBidPlaced` and the auction's
  `BidSubmitted` from the canonical receipt and checks them against the
  reviewed arguments and the auction's own bid record.
  """

  alias Autolaunch.BidPrice
  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.{LabAbi, LabRpc}
  alias Autolaunch.Robinhood.{BlockClock, Lab}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.Amounts

  @binding_keys [:stocks_launchpad, :bid_adapter, :usdg]
  @new_decimals 18
  @max_tick_walk 256
  @uint256_max Integer.pow(2, 256) - 1
  @bid_record_words 7

  def binding_keys, do: @binding_keys

  @spec snapshot(map()) :: {:ok, map()} | {:error, atom()}
  def snapshot(%{auction: auction, signer: signer, usdg_amount: usdg_amount, max_price_q96: max}) do
    with {:ok, auction} <- Address.normalize(auction),
         {:ok, config} <- Lab.current(),
         opts <- Lab.rpc_opts(config),
         adapter <- Lab.address!(config, :bid_adapter),
         launchpad <- Lab.address!(config, :stocks_launchpad),
         usdg <- Lab.address!(config, :usdg),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, clock} <- BlockClock.read(block, opts),
         :ok <- LabRpc.ensure_contract(adapter, block, opts),
         :ok <- LabRpc.ensure_contract(auction, block, opts),
         :ok <- adapter_bound(config, adapter, launchpad, usdg, block, opts),
         {:ok, stock} <- auction_stock(config, auction, block, opts),
         {:ok, words} <-
           launchpad_words(config, "stockAdmission(address)", [stock], 3, block, opts),
         {:ok, admission} <- admission(words),
         {:ok, route} <- routed(admission),
         {:ok, usdg_balance} <- usdg_uint(config, "balanceOf(address)", [signer], block, opts),
         {:ok, usdg_allowance} <- allowance(config, signer, block, opts),
         {:ok, stock_quote} <- stock_quote(config, route, usdg, stock, usdg_amount, block, opts),
         {:ok, facts} <- auction_facts(config, auction, clock, block, opts),
         {:ok, aligned} <- aligned_price(max, facts),
         {:ok, prev_tick} <- predecessor(config, auction, aligned, block, opts) do
      {:ok,
       %{
         adapter: adapter,
         usdg: usdg,
         stock: stock,
         stock_decimals: admission.decimals,
         admission: admission,
         usdg_balance: usdg_balance,
         usdg_allowance: usdg_allowance,
         stock_quote: stock_quote,
         auction: Map.put(facts, :address, auction),
         requested_max_price_q96: max,
         max_price_q96: aligned,
         prev_tick_price_q96: prev_tick,
         predecessor_source: "bounded local auction tick walk",
         block: block,
         clock: clock,
         lab_binding: Lab.binding(config, @binding_keys)
       }}
    else
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  @spec verify(map(), :usdg_approval | :usdg_bid, String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(envelope, step, hash) do
    with {:ok, result} <- verify_with_evidence(envelope, step, hash),
         do: {:ok, Map.delete(result, :receipt)}
  end

  def verify_with_evidence(envelope, step, hash) when step in [:usdg_approval, :usdg_bid] do
    with true <-
           Envelope.valid_for_confirmation?(envelope,
             resource: "autolaunch_robinhood_bid",
             chain_id: Lab.chain_id()
           ),
         true <- Lab.binding_matches?(envelope["metadata"]["lab"], @binding_keys),
         {:ok, config} <- Lab.current(),
         %{} = current <- current_step(envelope, step),
         opts <- Lab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, evidence} <-
           Rpc.canonical_outcome_evidence(
             hash,
             envelope["expected_signer"],
             current["to"],
             current["data"],
             block,
             opts
           ),
         {:ok, result} <- settled(evidence.outcome, envelope, step, config) do
      {:ok, Map.put(result, :receipt, evidence.receipt)}
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  defp settled(:pending, _envelope, _step, _config), do: {:ok, %{outcome: :pending}}
  defp settled(:reverted, _envelope, _step, _config), do: {:ok, %{outcome: :reverted}}

  # The allowance correction is confirmed only when USDG recorded exactly the
  # reviewed approval to the adapter and the standing allowance now equals it.
  defp settled({:success, logs}, envelope, :usdg_approval, config) do
    signer = envelope["expected_signer"]

    amount =
      envelope |> current_step(:usdg_approval) |> Map.fetch!("amount") |> String.to_integer()

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         true <-
           Abi.approval_recorded?(
             logs,
             Lab.address!(config, :usdg),
             signer,
             Lab.address!(config, :bid_adapter),
             amount
           ),
         {:ok, allowance} <- allowance(config, signer, block, Lab.rpc_opts(config)) do
      {:ok, %{outcome: if(allowance == amount, do: :confirmed, else: :unverified)}}
    else
      false -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The bid is confirmed only when the adapter's own event names the reviewed
  # auction, owner and maximum price with a net USDG spend no larger than the
  # reviewed amount (the adapter refunds any residue inside the call and emits
  # the net), the auction's own event records the same bid for the same owner,
  # amount and price, and the auction's bid record agrees at the receipt block.
  # The STOCK decimals for formatting are the launchpad's admission record for
  # this STOCK at that block; atomic amounts are the authoritative fields.
  defp settled({:success, logs}, envelope, :usdg_bid, config) do
    arguments = envelope["arguments"]
    signer = envelope["expected_signer"]
    opts = Lab.rpc_opts(config)
    adapter = Lab.address!(config, :bid_adapter)

    with {:ok, block} <- LabRpc.block_from_logs(logs),
         {:ok, placed} <- bid_placed(logs, config, adapter),
         true <- Address.equal?(placed.auction, arguments["auction"]),
         true <- Address.equal?(placed.owner, signer),
         true <- placed.max_price_q96 == integer(arguments, "max_price_q96"),
         true <- placed.usdg_spent <= integer(arguments, "usdg_amount_atomic"),
         {:ok, submitted} <- bid_submitted(logs, config, placed.auction),
         true <- submitted.bid_id == placed.bid_id,
         true <- Address.equal?(submitted.owner, signer),
         true <- submitted.price_q96 == placed.max_price_q96,
         true <- submitted.amount == placed.stock_committed,
         {:ok, record} <-
           auction_words(config, placed.auction, "bids(uint256)", [placed.bid_id], block, opts),
         true <- record_matches?(record, placed, signer),
         {:ok, stock} <- auction_stock(config, placed.auction, block, opts),
         {:ok, words} <-
           launchpad_words(config, "stockAdmission(address)", [stock], 3, block, opts),
         {:ok, admission} <- admission(words),
         {:ok, clearing} <-
           auction_uint(config, placed.auction, "clearingPrice()", [], block, opts) do
      {:ok,
       %{
         outcome: :confirmed,
         onchain_bid_id: Integer.to_string(placed.bid_id),
         result: %{
           "onchain_bid_id" => Integer.to_string(placed.bid_id),
           "usdg_spent_atomic" => Integer.to_string(placed.usdg_spent),
           "stock_committed_atomic" => Integer.to_string(placed.stock_committed),
           "stock_committed" => Rpc.format_units(placed.stock_committed, admission.decimals),
           "stock_decimals" => Integer.to_string(admission.decimals),
           "max_price_q96" => Integer.to_string(placed.max_price_q96),
           "current_clearing_price" =>
             Amounts.format_cca_price(clearing, admission.decimals, @new_decimals),
           "local_block_hash" => block.hash
         }
       }}
    else
      false -> {:ok, %{outcome: :unverified}}
      :error -> {:ok, %{outcome: :unverified}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bid_placed(logs, config, adapter) do
    with {:ok, {[auction_word, owner_word, bid_id], [usdg_spent, stock_committed, price]}} <-
           LabAbi.event_words(
             Lab.abi!(config, :bid_adapter),
             RobinhoodLabAbi.stock_bid_placed_signature(),
             logs,
             adapter
           ),
         {:ok, auction} <- Abi.word_address(auction_word),
         {:ok, owner} <- Abi.word_address(owner_word) do
      {:ok,
       %{
         auction: auction,
         owner: owner,
         bid_id: bid_id,
         usdg_spent: usdg_spent,
         stock_committed: stock_committed,
         max_price_q96: price
       }}
    else
      _ -> :error
    end
  end

  defp bid_submitted(logs, config, auction) do
    with {:ok, {[bid_id, owner_word], [price, amount]}} <-
           LabAbi.event_words(
             Lab.abi!(config, :auction),
             RobinhoodLabAbi.bid_submitted_signature(),
             logs,
             auction
           ),
         {:ok, owner} <- Abi.word_address(owner_word) do
      {:ok, %{bid_id: bid_id, owner: owner, price_q96: price, amount: amount}}
    else
      _ -> :error
    end
  end

  # `bids(bidId)`: startBlock, startCumulativeMps, exitedBlock, maxPrice, owner,
  # amountQ96 (the committed STOCK shifted left by 96 bits), tokensFilled. Only
  # the immutable fields are checked; whether the bid was since exited is
  # lifecycle, not submission evidence.
  defp record_matches?(
         [_start_block, _start_mps, _exited_block, max_price, owner_word, amount_q96, _filled],
         placed,
         signer
       ) do
    case Abi.word_address(owner_word) do
      {:ok, owner} ->
        Address.equal?(owner, signer) and max_price == placed.max_price_q96 and
          amount_q96 == Bitwise.bsl(placed.stock_committed, 96)

      :error ->
        false
    end
  end

  defp record_matches?(_record, _placed, _signer), do: false

  # The adapter is bound at construction to one launchpad and that launchpad's
  # USDG; a lab whose adapter names other contracts is not the reviewed lab.
  defp adapter_bound(config, adapter, launchpad, usdg, block, opts) do
    abi = Lab.abi!(config, :bid_adapter)

    with {:ok, bound_launchpad} <-
           Rpc.call_address(adapter, LabAbi.encode(abi, "launchpad()", []), block, opts),
         {:ok, bound_usdg} <-
           Rpc.call_address(adapter, LabAbi.encode(abi, "usdg()", []), block, opts),
         true <- Address.equal?(bound_launchpad, launchpad) and Address.equal?(bound_usdg, usdg) do
      :ok
    else
      false -> {:error, :lab_config_changed}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_chain_response}
    end
  end

  # The STOCK an auction sells for: the launchpad's record for that auction and
  # the auction's own currency must name the same token.
  defp auction_stock(config, auction, block, opts) do
    with {:ok, launch_id} <-
           launchpad_uint(config, "launchIdOfAuction(address)", [auction], block, opts),
         true <- launch_id > 0 || {:error, :unknown_auction},
         {:ok, record} <-
           launchpad_words(
             config,
             "launches(uint256)",
             [launch_id],
             RobinhoodLabAbi.launch_record_words(),
             block,
             opts
           ),
         {:ok, stock} <- record |> Enum.at(2) |> Abi.word_address(),
         {:ok, currency} <- auction_address(config, auction, "currency()", [], block, opts),
         true <- Address.equal?(stock, currency) do
      {:ok, stock}
    else
      false -> {:error, :invalid_chain_response}
      :error -> {:error, :invalid_chain_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # `stockAdmission(stock)`: admitted, decimals, route. A stock that was never
  # admitted answers false, 0 and the zero route; a revoked stock answers false
  # with the decimals and route it was admitted with, and its existing auctions
  # keep bidding through that route. An admitted stock always has a route.
  defp admission([admitted, decimals, route])
       when admitted in [0, 1] and decimals in 0..255 do
    case {admitted, Abi.word_address(route), route} do
      {1, {:ok, route}, _word} -> {:ok, %{admitted: true, decimals: decimals, route: route}}
      {0, {:ok, route}, _word} -> {:ok, %{admitted: false, decimals: decimals, route: route}}
      {0, :error, 0} -> {:ok, %{admitted: false, decimals: decimals, route: nil}}
      _other -> :error
    end
  end

  defp admission(_words), do: :error

  defp routed(%{route: nil}), do: {:error, :stock_route_unavailable}
  defp routed(%{route: route}), do: {:ok, route}

  defp stock_quote(config, route, usdg, stock, usdg_amount, block, opts) do
    Rpc.call_uint(
      route,
      LabAbi.encode(
        Lab.abi!(config, :stock_route),
        "quoteExactIn(address,address,uint256)",
        [usdg, stock, usdg_amount]
      ),
      block,
      opts
    )
  end

  # The schedule and price limits are plain reads at any block. `checkpoint()`
  # reverts before the start block, so its clearing price is simulated (an
  # eth_call pinned to the snapshot block, never a transaction) only once the
  # auction is active; before that the stored `clearingPrice()` is the only
  # clearing price there is, and the snapshot says which one it reports.
  defp auction_facts(config, auction, clock, block, opts) do
    with {:ok, spacing} <- auction_uint(config, auction, "tickSpacing()", [], block, opts),
         {:ok, floor} <- auction_uint(config, auction, "floorPrice()", [], block, opts),
         {:ok, cap} <- auction_uint(config, auction, "MAX_BID_PRICE()", [], block, opts),
         {:ok, stored} <- auction_uint(config, auction, "clearingPrice()", [], block, opts),
         {:ok, start_block} <- auction_uint(config, auction, "startBlock()", [], block, opts),
         {:ok, end_block} <- auction_uint(config, auction, "endBlock()", [], block, opts),
         {:ok, claim_block} <- auction_uint(config, auction, "claimBlock()", [], block, opts),
         {:ok, graduated} <- auction_bool(config, auction, "isGraduated()", [], block, opts),
         {:ok, simulated} <-
           simulated_clearing(config, auction, start_block, clock, block, opts) do
      {:ok,
       %{
         tick_spacing_q96: spacing,
         floor_price_q96: floor,
         max_bid_price_q96: cap,
         stored_clearing_price_q96: stored,
         simulated_clearing_price_q96: simulated,
         clearing_price_q96: simulated || stored,
         clearing_price_source:
           if(simulated, do: "simulated checkpoint", else: "stored clearingPrice"),
         start_block: start_block,
         end_block: end_block,
         claim_block: claim_block,
         graduated: graduated
       }}
    end
  end

  defp simulated_clearing(_config, _auction, start_block, clock, _block, _opts)
       when clock < start_block,
       do: {:ok, nil}

  defp simulated_clearing(config, auction, _start_block, _clock, block, opts) do
    with {:ok, [clearing, _raised, _mps_per_price, _mps, _prev, _next]} <-
           auction_words(config, auction, "checkpoint()", [], block, opts, 6),
         do: {:ok, clearing}
  end

  # A review without a maximum price has nothing to align and no predecessor.
  defp aligned_price(nil, _facts), do: {:ok, nil}
  defp aligned_price(max, facts), do: BidPrice.align(max, facts)

  # The initialised tick just below the aligned price, found by walking the
  # auction's own tick list from the floor: bounded, and refused when the list
  # stops making progress.
  defp predecessor(_config, _auction, nil, _block, _opts), do: {:ok, 0}

  defp predecessor(config, auction, max_price, block, opts) do
    with {:ok, floor} <- auction_uint(config, auction, "floorPrice()", [], block, opts),
         true <- floor < max_price do
      walk_ticks(config, auction, floor, max_price, block, opts, 0)
    else
      false -> {:error, :bid_preparation_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_ticks(_config, _auction, _current, _max_price, _block, _opts, @max_tick_walk),
    do: {:error, :bid_preparation_unavailable}

  defp walk_ticks(config, auction, current, max_price, block, opts, hops) do
    with {:ok, [next, _demand]} <-
           auction_words(config, auction, "ticks(uint256)", [current], block, opts, 2) do
      cond do
        next == @uint256_max -> {:ok, current}
        next >= max_price -> {:ok, current}
        next > current -> walk_ticks(config, auction, next, max_price, block, opts, hops + 1)
        true -> {:error, :bid_preparation_unavailable}
      end
    end
  end

  defp auction_uint(config, auction, signature, arguments, block, opts),
    do: Rpc.call_uint(auction, auction_data(config, signature, arguments), block, opts)

  defp auction_bool(config, auction, signature, arguments, block, opts),
    do: Rpc.call_bool(auction, auction_data(config, signature, arguments), block, opts)

  defp auction_address(config, auction, signature, arguments, block, opts),
    do: Rpc.call_address(auction, auction_data(config, signature, arguments), block, opts)

  defp auction_words(
         config,
         auction,
         signature,
         arguments,
         block,
         opts,
         count \\ @bid_record_words
       ),
       do: Rpc.call_words(auction, auction_data(config, signature, arguments), block, count, opts)

  defp auction_data(config, signature, arguments),
    do: LabAbi.encode(Lab.abi!(config, :auction), signature, arguments)

  defp launchpad_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
      block,
      opts
    )
  end

  defp launchpad_words(config, signature, arguments, count, block, opts) do
    Rpc.call_words(
      Lab.address!(config, :stocks_launchpad),
      LabAbi.encode(Lab.abi!(config, :stocks_launchpad), signature, arguments),
      block,
      count,
      opts
    )
  end

  defp usdg_uint(config, signature, arguments, block, opts) do
    Rpc.call_uint(
      Lab.address!(config, :usdg),
      LabAbi.encode(Lab.abi!(config, :erc20), signature, arguments),
      block,
      opts
    )
  end

  defp allowance(config, signer, block, opts) do
    usdg_uint(
      config,
      "allowance(address,address)",
      [signer, Lab.address!(config, :bid_adapter)],
      block,
      opts
    )
  end

  defp current_step(envelope, step) do
    name = Atom.to_string(step)
    Enum.find(envelope["arguments"]["steps"], &(&1["step"] == name))
  end

  defp integer(arguments, key), do: arguments |> Map.fetch!(key) |> String.to_integer()
end
