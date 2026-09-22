defmodule Autolaunch.Robinhood.StockBidActions do
  @moduledoc """
  The one boundary between a bidder's wallet and a Robinhood memestock auction.

  Preparation reads the local Robinhood lab and returns the whole reviewed
  sequence as a single immutable envelope: at most an exact USDG allowance for
  the bid adapter, then the one `bidWithUsdg` call it enables. Nothing is
  written anywhere. The chain is the only record of what a wallet bid:
  confirmation reads the canonical receipt through
  `Autolaunch.Robinhood.StockBidChainClient`, and a wallet's bids are the
  auction's own `BidSubmitted` records for that wallet.

  Every call binds to the signed-in wallet of the account the session lease
  names, read inside the lease at call time: the wallet the page presents must
  be exactly that wallet, never another linked address.

  The USDG amount is the most the wallet may spend; the adapter converts it
  into the auction's STOCK through the admitted route and returns any residue
  inside the same call. The lowest STOCK the bid accepts and the deadline are
  exact limits the wallet signs; only today's quote and the time remaining are
  estimates.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Address, Envelope, Rpc}
  alias Autolaunch.LabAbi
  alias Autolaunch.Robinhood.{BlockClock, Lab, StockBidChainClient}
  alias Autolaunch.Robinhood.LabAbi, as: RobinhoodLabAbi
  alias Autolaunch.Stocks.{Amounts, Assets, LaunchOperations}

  @resource "autolaunch_robinhood_bid"
  @action "autolaunch_robinhood_bid"
  @contract_name "RobinhoodStockBidAdapterV1"
  @new_decimals 18
  @usdg_decimals 6
  # The lowest STOCK accepted is at most one percent below today's quote.
  @tolerance_divisor 100
  @deadline_seconds 900
  @uint128_max Integer.pow(2, 128) - 1
  # The last second the calendar can state (year 9999) less the deadline lead,
  # so the deadline the review shows is always one it can state.
  @max_header_seconds 253_402_300_799 - @deadline_seconds
  @bid_record_words 7
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  @doc """
  Reviews one USDG bid on one auction for the signed-in wallet: a bounded
  discovery read for the STOCK's decimals, the final snapshot at one pinned
  block, one immutable envelope, the reviewed steps and the plain facts the
  page shows.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%{auction: auction, usdg_amount: usdg_amount, max_price: max_price}, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, config} <- robinhood_lab(),
         {:ok, auction} <- address(auction, :invalid_auction),
         {:ok, usdg_amount} <- usdg_amount(usdg_amount),
         {:ok, discovery} <- snapshot(auction, signer, usdg_amount, nil),
         {:ok, price} <- max_price(max_price, discovery.stock_decimals),
         {:ok, snapshot} <- snapshot(auction, signer, usdg_amount, price.candidate_price_q96),
         :ok <- consistent(discovery, snapshot, config),
         {:ok, header} <- block_header(snapshot.block, Lab.rpc_opts(config)),
         {:ok, asset} <- listed_stock(snapshot.stock),
         {:ok, executable} <- executable(usdg_amount, price, snapshot, header),
         do: {:ok, build(executable, asset, signer, snapshot, config)}
  end

  @doc """
  Reads one sent step back from the chain for the signed-in wallet. The result
  is the chain client's own answer: `:pending`, `:reverted`, `:unverified`, or
  `:confirmed` with the auction's record of the bid.
  """
  @spec verify(map(), :usdg_approval | :usdg_bid, String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify(envelope, step, hash, opts)
      when is_map(envelope) and step in [:usdg_approval, :usdg_bid] do
    with {:ok, actor} <- human(opts),
         {:ok, _signer} <- current_wallet(envelope["expected_signer"], actor, opts),
         {:ok, hash} <- canonical_hash(hash),
         {:ok, config} <- robinhood_lab(),
         true <- valid_envelope?(envelope, config) || unavailable(:envelope_invalid),
         do: read_chain(envelope, step, hash)
  end

  def verify(_envelope, _step, _hash, _opts), do: unavailable(:unknown_step)

  @doc """
  Every bid the auction records for the signed-in wallet, read at one pinned
  block: the `BidSubmitted` logs for that owner from the chain's first block to
  the pinned block, each confirmed against `bids(bidId)` at the same block on
  the fields a bid never changes. A malformed log or a record that disagrees
  refuses the whole read rather than dropping an entry. A bid that has since
  exited or been claimed is still listed; its current state is stated as such.
  The same read states the auction's STOCK and its bidding window, so the page
  can name the currency and say whether bidding is open before any review.
  """
  @spec bids(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bids(auction, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, config} <- robinhood_lab(),
         {:ok, auction} <- address(auction, :invalid_auction),
         rpc <- Lab.rpc_opts(config),
         {:ok, block} <- chain(Rpc.latest_block(rpc)),
         {:ok, clock} <- chain(BlockClock.read(block, rpc)),
         {:ok, stock, decimals} <- stock_decimals(auction, block, config, rpc),
         {:ok, asset} <- listed_stock(stock),
         {:ok, window} <- bidding_window(auction, block, config, rpc),
         {:ok, graduated?} <- graduated?(auction, block, config, rpc),
         {:ok, logs} <- bid_logs(auction, signer, block, rpc),
         {:ok, bids} <- bid_records(logs, auction, signer, decimals, block, config, rpc) do
      {:ok,
       %{
         block: block,
         clock: clock,
         bids: bids,
         stock: %{"address" => stock, "symbol" => asset.symbol},
         window: window,
         graduated?: graduated?
       }}
    end
  end

  # Inputs

  defp usdg_amount(value) when is_binary(value) do
    with {:ok, amount} <- Amounts.parse_units(value, @usdg_decimals) |> refusable(),
         true <- amount > 0 || unavailable(:amount_required),
         do: {:ok, amount}
  end

  defp usdg_amount(_value), do: unavailable(:amount_required)

  defp max_price(value, decimals) when is_binary(value),
    do: Amounts.cca_price(value, decimals, @new_decimals) |> refusable()

  defp max_price(_value, _decimals), do: unavailable(:max_price_required)

  # Both reads must come from the lab this review is built on, and the final
  # snapshot must describe the same auction and STOCK the discovery read did,
  # or the review would mix two states.
  defp consistent(discovery, snapshot, config) do
    binding = Lab.binding(config, StockBidChainClient.binding_keys())

    cond do
      discovery.lab_binding != binding or snapshot.lab_binding != binding ->
        unavailable(:lab_config_changed)

      not Address.equal?(discovery.auction.address, snapshot.auction.address) or
        not Address.equal?(discovery.stock, snapshot.stock) or
          discovery.stock_decimals != snapshot.stock_decimals ->
        unavailable(:invalid_chain_response)

      true ->
        :ok
    end
  end

  defp listed_stock(stock) do
    case Assets.fetch(Lab.chain_id(), stock) do
      {:ok, asset} -> {:ok, asset}
      _missing -> unavailable(:stock_not_listed)
    end
  end

  # Executable values

  defp executable(usdg_amount, price, snapshot, header) do
    with :ok <- biddable(usdg_amount, snapshot),
         {:ok, min_stock_out} <-
           bounded(
             snapshot.stock_quote - div(snapshot.stock_quote, @tolerance_divisor),
             @uint128_max,
             :quote_out_of_range
           ) do
      {:ok,
       %{
         usdg_amount: usdg_amount,
         stock_quote: snapshot.stock_quote,
         min_stock_out: min_stock_out,
         max_price_entered: price.entered_stock_per_new,
         max_price_q96: snapshot.max_price_q96,
         max_price_adjusted:
           price.adjustment_required or snapshot.max_price_q96 != price.candidate_price_q96,
         prev_tick_price_q96: snapshot.prev_tick_price_q96,
         deadline: header.timestamp + @deadline_seconds,
         block_timestamp: header.timestamp,
         stock_decimals: snapshot.stock_decimals
       }}
    end
  end

  defp biddable(usdg_amount, %{usdg_balance: balance}) when balance < usdg_amount,
    do: unavailable(:amount_above_balance)

  defp biddable(_usdg_amount, %{stock_quote: 0}), do: unavailable(:usdg_route_unavailable)

  defp biddable(_usdg_amount, %{clock: clock, auction: auction})
       when clock < auction.start_block or clock >= auction.end_block,
       do: unavailable(:auction_not_open)

  defp biddable(_usdg_amount, _snapshot), do: :ok

  defp bounded(value, max, _reason) when is_integer(value) and value > 0 and value <= max,
    do: {:ok, value}

  defp bounded(_value, _max, reason), do: unavailable(reason)

  # The review

  defp build(executable, asset, signer, snapshot, config) do
    steps = reviewed_steps(executable, snapshot, config)
    data = steps |> List.last() |> Map.fetch!("data")

    envelope =
      @action
      |> Envelope.new(signer, data,
        to: snapshot.adapter,
        resource: @resource,
        contract_name: @contract_name,
        chain_id: Lab.chain_id(),
        lab_binding: snapshot.lab_binding,
        risk_copy: risk_copy(executable, asset),
        arguments: %{
          "auction" => snapshot.auction.address,
          "stock" => snapshot.stock,
          "stock_symbol" => asset.symbol,
          "stock_decimals" => Integer.to_string(executable.stock_decimals),
          "usdg_amount" => usdg_units(executable.usdg_amount),
          "usdg_amount_atomic" => Integer.to_string(executable.usdg_amount),
          "stock_quote_atomic" => Integer.to_string(executable.stock_quote),
          "stock_quote_units" => stock_units(executable.stock_quote, executable),
          "min_stock_out_atomic" => Integer.to_string(executable.min_stock_out),
          "min_stock_out_units" => stock_units(executable.min_stock_out, executable),
          "max_price_entered" => executable.max_price_entered,
          "max_price_q96" => Integer.to_string(executable.max_price_q96),
          "max_price_executable" => stock_per_new(executable.max_price_q96, executable),
          "max_price_adjusted" => executable.max_price_adjusted,
          "prev_tick_price_q96" => Integer.to_string(executable.prev_tick_price_q96),
          "deadline" => Integer.to_string(executable.deadline),
          "usdg_balance_atomic" => Integer.to_string(snapshot.usdg_balance),
          "usdg_allowance_atomic" => Integer.to_string(snapshot.usdg_allowance),
          "adapter" => snapshot.adapter,
          "usdg" => snapshot.usdg,
          "route" => snapshot.admission.route,
          "auction_start_block" => Integer.to_string(snapshot.auction.start_block),
          "auction_end_block" => Integer.to_string(snapshot.auction.end_block),
          "block_number" => snapshot.block.number,
          "block_hash" => snapshot.block.hash,
          "block_timestamp" => executable.block_timestamp,
          "steps" => steps
        }
      )
      |> stored()

    %{envelope: envelope, steps: steps, review: review(executable, asset)}
  end

  # The plain facts the page shows before anything is signed.
  defp review(executable, asset) do
    [
      ["You spend up to", "#{usdg_units(executable.usdg_amount)} USDG"],
      [
        "Worth today",
        "#{compact(stock_units(executable.stock_quote, executable))} #{asset.symbol} at today's route quote"
      ],
      [
        "Lowest #{asset.symbol} you accept",
        "#{compact(stock_units(executable.min_stock_out, executable))} #{asset.symbol}, at most 1% below today's quote"
      ],
      ["Max price", max_price_copy(executable, asset)],
      [
        "Must be included by",
        "#{block_time(executable.deadline)}, about #{div(@deadline_seconds, 60)} minutes after this review"
      ]
    ]
  end

  defp max_price_copy(executable, asset) do
    price =
      "#{compact(stock_per_new(executable.max_price_q96, executable))} #{asset.symbol} per NEW"

    if executable.max_price_adjusted,
      do: "#{price}, adjusted down from the #{executable.max_price_entered} you entered",
      else: price
  end

  defp risk_copy(executable, asset) do
    network =
      if Lab.test_chain?(),
        do: "the local Robinhood lab with test assets and no mainnet value",
        else: "Robinhood Chain (chain #{Lab.chain_id()})"

    "Your wallet bids on this auction on #{network}. Up to #{usdg_units(executable.usdg_amount)} USDG is converted into #{asset.symbol} for the bid; any unspent part comes back to you in the same transaction."
  end

  # The reviewed sequence: the exact allowance for the bid amount when the
  # standing allowance is below it, then the one `bidWithUsdg` call it enables.
  defp reviewed_steps(executable, snapshot, config) do
    approval_step(executable, snapshot, config) ++
      [
        %{
          "step" => "usdg_bid",
          "to" => snapshot.adapter,
          "data" => bid_data(executable, snapshot, config)
        }
      ]
  end

  defp approval_step(%{usdg_amount: amount}, %{usdg_allowance: allowance}, _config)
       when allowance >= amount,
       do: []

  defp approval_step(%{usdg_amount: amount}, %{usdg: usdg, adapter: adapter}, config) do
    [
      %{
        "step" => "usdg_approval",
        "to" => usdg,
        "data" =>
          LabAbi.encode(Lab.abi!(config, :erc20), "approve(address,uint256)", [adapter, amount]),
        "amount" => Integer.to_string(amount),
        "spender" => adapter
      }
    ]
  end

  defp bid_data(executable, snapshot, config) do
    LabAbi.encode(
      Lab.abi!(config, :bid_adapter),
      "bidWithUsdg(address,uint256,uint128,uint256,uint256,uint256)",
      [
        snapshot.auction.address,
        executable.usdg_amount,
        executable.min_stock_out,
        executable.max_price_q96,
        executable.prev_tick_price_q96,
        executable.deadline
      ]
    )
  end

  defp usdg_units(amount), do: Rpc.format_units(amount, @usdg_decimals)

  defp stock_units(amount, %{stock_decimals: decimals}), do: Rpc.format_units(amount, decimals)

  defp stock_per_new(q96, %{stock_decimals: decimals}),
    do: Amounts.format_cca_price(q96, decimals, @new_decimals)

  # The page shows a readable amount; the envelope keeps the exact one.
  defp compact(value), do: Amounts.compact_decimal(value)

  defp block_time(unix),
    do: unix |> DateTime.from_unix!() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Confirmation

  # The expected target is the current lab's bid adapter, never a field of the
  # envelope under review.
  defp valid_envelope?(envelope, config) do
    Envelope.valid_for_confirmation?(envelope,
      resource: @resource,
      action: @action,
      signer: envelope["expected_signer"],
      to: Lab.address!(config, :bid_adapter),
      contract_name: @contract_name,
      chain_id: Lab.chain_id()
    )
  end

  defp read_chain(envelope, step, hash) do
    case StockBidChainClient.verify(envelope, step, hash) do
      {:ok, result} -> {:ok, result}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # A wallet's bids, from the auction's own records

  defp bid_logs(auction, signer, block, rpc) do
    topic = LabAbi.topic(RobinhoodLabAbi.bid_submitted_signature())

    filter = %{
      address: auction,
      fromBlock: "0x0",
      toBlock: quantity(block.number),
      topics: [topic, nil, topic_address(signer)]
    }

    case Rpc.request("eth_getLogs", [filter], rpc) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> unavailable(:invalid_chain_response)
      {:error, reason} -> chain({:error, reason})
    end
  end

  defp bid_records(logs, auction, signer, decimals, block, config, rpc) do
    abi = Lab.abi!(config, :auction)

    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, bids} ->
      with {:ok, submitted} <- bid_submitted(abi, log, auction, signer),
           {:ok, record} <-
             Rpc.call_words(
               auction,
               LabAbi.encode(abi, "bids(uint256)", [submitted.bid_id]),
               block,
               @bid_record_words,
               rpc
             ),
           {:ok, bid} <- bid_record(submitted, record, decimals) do
        {:cont, {:ok, [bid | bids]}}
      else
        {:error, :chain_unavailable} -> {:halt, unavailable(:chain_unavailable)}
        _malformed -> {:halt, unavailable(:invalid_chain_response)}
      end
    end)
    |> case do
      {:ok, bids} -> {:ok, Enum.reverse(bids)}
      error -> error
    end
  end

  # One `BidSubmitted(bidId, owner, priceQ96, amount)` log, amount in atomic
  # STOCK, refused unless the owner is the signed-in wallet.
  defp bid_submitted(abi, log, auction, signer) do
    with {:ok, {[bid_id, owner_word], [price_q96, amount]}} <-
           LabAbi.event_words(abi, RobinhoodLabAbi.bid_submitted_signature(), [log], auction),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(owner, signer) do
      {:ok, %{bid_id: bid_id, owner: owner, price_q96: price_q96, amount: amount}}
    else
      _ -> :error
    end
  end

  # `bids(bidId)`: startBlock, startCumulativeMps, exitedBlock, maxPrice, owner,
  # amountQ96 (the committed STOCK shifted left by 96 bits), tokensFilled. The
  # owner, price and amount must repeat the event exactly; the exit block and
  # the tokens filled are the bid's current state, and a claim sets the tokens
  # filled back to zero, so neither says whether the bid was ever filled.
  defp bid_record(
         submitted,
         [
           start_block,
           _start_mps,
           exited_block,
           max_price,
           owner_word,
           amount_q96,
           tokens_filled
         ],
         decimals
       ) do
    with {:ok, owner} <- Abi.word_address(owner_word),
         true <-
           Address.equal?(owner, submitted.owner) and max_price == submitted.price_q96 and
             amount_q96 == Bitwise.bsl(submitted.amount, 96) do
      {:ok,
       %{
         "bid_id" => Integer.to_string(submitted.bid_id),
         "owner" => owner,
         "max_price_q96" => Integer.to_string(max_price),
         "stock_committed_atomic" => Integer.to_string(submitted.amount),
         "stock_committed_units" => Rpc.format_units(submitted.amount, decimals),
         "start_block" => Integer.to_string(start_block),
         "exited_block" => Integer.to_string(exited_block),
         "tokens_filled_now" => Integer.to_string(tokens_filled)
       }}
    else
      _ -> :error
    end
  end

  defp bid_record(_submitted, _record, _decimals), do: :error

  # The STOCK an auction sells for and its admitted decimals, from the auction's
  # own currency and the launchpad's admission record at the pinned block.
  defp stock_decimals(auction, block, config, rpc) do
    launchpad = Lab.address!(config, :stocks_launchpad)

    with {:ok, stock} <-
           Rpc.call_address(
             auction,
             LabAbi.encode(Lab.abi!(config, :auction), "currency()", []),
             block,
             rpc
           ),
         {:ok, [_admitted, decimals, _route]} <-
           Rpc.call_words(
             launchpad,
             LabAbi.encode(Lab.abi!(config, :stocks_launchpad), "stockAdmission(address)", [stock]),
             block,
             3,
             rpc
           ),
         true <- decimals in 0..255 do
      {:ok, stock, decimals}
    else
      {:error, reason} -> chain({:error, reason})
      _malformed -> unavailable(:invalid_chain_response)
    end
  end

  # Whether the auction raised what it required, at the pinned block. Final once
  # bidding has ended and any bid has exited, since every exit checkpoints first.
  defp graduated?(auction, block, config, rpc) do
    abi = Lab.abi!(config, :auction)

    chain(Rpc.call_bool(auction, LabAbi.encode(abi, "isGraduated()", []), block, rpc))
  end

  # The auction's own first and last bidding blocks at the pinned block.
  defp bidding_window(auction, block, config, rpc) do
    abi = Lab.abi!(config, :auction)

    with {:ok, start_block} <-
           Rpc.call_uint(auction, LabAbi.encode(abi, "startBlock()", []), block, rpc),
         {:ok, end_block} <-
           Rpc.call_uint(auction, LabAbi.encode(abi, "endBlock()", []), block, rpc) do
      {:ok, %{"start_block" => start_block, "end_block" => end_block}}
    else
      {:error, reason} -> chain({:error, reason})
      _malformed -> unavailable(:invalid_chain_response)
    end
  end

  defp topic_address("0x" <> hex), do: "0x" <> String.pad_leading(hex, 64, "0")

  defp quantity(number), do: "0x" <> Integer.to_string(number, 16)

  # Chain snapshot

  defp robinhood_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:robinhood_unavailable)
    end
  end

  defp snapshot(auction, signer, usdg_amount, max_price_q96) do
    chain(
      StockBidChainClient.snapshot(%{
        auction: auction,
        signer: signer,
        usdg_amount: usdg_amount,
        max_price_q96: max_price_q96
      })
    )
  end

  # The header of the snapshot block itself, by hash, so the timestamp belongs
  # to the same block every read above was pinned to.
  defp block_header(%{hash: hash}, rpc) do
    with {:ok, %{"hash" => header_hash, "timestamp" => "0x" <> hex}}
         when is_binary(header_hash) and is_binary(hex) <-
           Rpc.request("eth_getBlockByHash", [hash, false], rpc),
         true <- String.downcase(header_hash) == hash,
         true <- Regex.match?(~r/^[0-9a-f]+$/i, hex),
         {timestamp, ""} when timestamp in 0..@max_header_seconds <- Integer.parse(hex, 16) do
      {:ok, %{timestamp: timestamp}}
    else
      {:error, reason} -> chain({:error, reason})
      _other -> unavailable(:invalid_block_header)
    end
  end

  defp chain({:ok, value}), do: {:ok, value}
  defp chain({:error, reason}) when reason in @transient, do: unavailable(:chain_unavailable)
  defp chain({:error, reason}), do: unavailable(reason)

  # Session and wallet identity

  defp human(opts) do
    case Keyword.get(opts, :actor) do
      %Human{} = actor -> {:ok, actor}
      _anonymous -> unavailable(:authentication_required)
    end
  end

  defp lease(opts) do
    case Keyword.get(opts, :context) do
      %{session_lease: %{lineage: lineage, account_id: account_id}}
      when is_binary(lineage) and is_integer(account_id) ->
        {:ok, %{lineage: lineage, account_id: account_id}}

      _absent ->
        unavailable(:session_lease_required)
    end
  end

  # The wallet the page presents has to be the signed-in wallet of the leased
  # account, read now: not another linked address, and never a guess.
  defp current_wallet(address, actor, opts) do
    with {:ok, candidate} <- address(address, :invalid_address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         do: signed_in_wallet(account, candidate)
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  defp signed_in_wallet(%{wallet_address: wallet}, candidate) when is_binary(wallet) do
    if Address.equal?(wallet, candidate), do: {:ok, candidate}, else: unavailable(:wrong_signer)
  end

  defp signed_in_wallet(_account, _candidate), do: unavailable(:wrong_signer)

  # Shared helpers

  defp canonical_hash(hash) do
    if Rpc.valid_hash?(hash), do: {:ok, String.downcase(hash)}, else: unavailable(:invalid_hash)
  end

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  defp refusable({:error, reason}), do: unavailable(reason)
  defp refusable(result), do: result

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
