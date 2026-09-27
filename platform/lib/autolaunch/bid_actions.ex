defmodule Autolaunch.BidActions do
  @moduledoc """
  The one boundary between a bidder and a Base auction.

  A review reads Base once, proves the auction really raises for the treasury
  this site recorded, and returns the steps the wallet sends in turn. Nothing
  is written: the review lives on the page, the wallet sends its steps, and
  the page reads what the bid placed from its receipt. The chain watcher
  records every bid an auction announces as its bidder's position.

  Every review binds to one of the wallets of the account the session lease
  names, read at call time: the page's active wallet must be one the account
  links, never a guess.
  """

  alias Autolaunch
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Abi, Client, Rpc}
  alias Autolaunch.{ChainClient, Lab, LabAbi, LabBidChainClient, TreasurySecurity}
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias Autolaunch.Stocks.LabAbi, as: StocksLabAbi
  alias RegentChain.{Address, Review}

  # A bid amount is denominated in the auction's own currency, whose decimals
  # the stored auction row records: REGENT's eighteen, or the admitted stock's.
  @usdc_decimals 6
  @new_decimals 18
  # The USDC route estimate is never binding; the bid demands this much of it.
  @usdc_tolerance_bps 100
  @usdc_deadline_seconds 900
  @q96 79_228_162_514_264_337_593_543_950_336
  @uint128_max Integer.pow(2, 128) - 1
  @uint256_max Integer.pow(2, 256) - 1

  # A Permit2 allowance is granted for thirty minutes, and one that would
  # lapse within ten, the longest a review stays on the page before it is
  # built again, is granted again rather than relied on.
  @permit2_seconds 1800
  @reuse_seconds 600

  # A Base read that may answer differently later never settles anything.
  @transient [
    :chain_unavailable,
    :invalid_chain_response,
    :invalid_block_header,
    :transaction_missing
  ]

  @doc """
  The public estimate for one auction, from its stored snapshot.

  A refusal names the first thing that stopped it, checked in this order:
  `:auction_not_found` (the id names no auction this site created),
  `:invalid_amount`, `:invalid_max_price`, or `:database_unavailable` when the
  stored auction could not be read.
  """
  def quote(auction_id, amount, max_price, opts \\ []) do
    with {:ok, auction} <- quoted_auction(auction_id, opts),
         {:ok, amount} <- positive_decimal(amount, :invalid_amount),
         {:ok, max_price} <- positive_decimal(max_price, :invalid_max_price) do
      current_price = nonnegative_decimal_or_zero(auction.current_clearing_price)
      projected_price = if Decimal.gt?(current_price, 0), do: current_price, else: max_price
      active? = Decimal.compare(max_price, current_price) != :lt

      estimated_tokens =
        if active? and Decimal.gt?(projected_price, 0),
          do: Decimal.div(amount, projected_price),
          else: Decimal.new(0)

      {:ok,
       %{
         auction_id: auction.id,
         amount: decimal_string(amount),
         max_price: decimal_string(max_price),
         quote_token: %{
           address: auction.quote_token_address,
           symbol: auction.quote_token_symbol,
           decimals: auction.quote_token_decimals
         },
         current_clearing_price: decimal_string(current_price),
         projected_clearing_price: decimal_string(projected_price),
         would_be_active_now: active?,
         status_band: status_band(active?, max_price, projected_price),
         estimated_tokens_if_end_now: decimal_string(estimated_tokens),
         warnings: quote_warnings(auction, active?)
       }}
    end
  end

  @doc """
  What one of the signed-in account's wallets may spend on this auction.

  The address is proved against the account the mounted lease resolves to before
  any private fact is read, so a wallet the account does not link is refused
  rather than answered about.
  """
  def position(input, %{actor: %Human{}} = context) do
    with {:ok, signer} <- current_wallet(input.arguments.expected_signer, context.actor, context),
         {:ok, auction} <- auction(input.arguments.auction_id),
         {:ok, auction_address} <- normalize(auction.auction_address),
         {:ok, snapshot} <- snapshot(auction_address, signer, nil),
         :ok <- bound_currency(snapshot, auction) do
      {:ok, %{signer: signer, balance: Integer.to_string(snapshot.currency_balance)}}
    end
  end

  def position(_input, _context), do: {:error, :authentication_required}

  @doc """
  The steps of one bid for `address`, one of the signed-in account's wallets,
  with the facts the page shows beside them and what the page needs to read
  the bid from its receipt. `request` names the auction, the amount typed, the
  most per token and the currency paid (`"USDC"` on a Stocks auction that takes
  it, otherwise the auction's own).

  A bid in the auction's own currency carries only the transactions this
  wallet still needs: an exact approval to canonical Permit2, an exact
  short-lived Permit2 allowance for this auction, then the canonical
  five-argument bid. A USDC bid carries the exact USDC allowance to the bid
  adapter it still needs, then the adapter call that buys the stock through
  the admitted route and places the bid as this wallet; the route's estimate is
  shown and never trusted, as the adapter is told to deliver at least the
  estimate less one percent or revert, and to refuse the call after fifteen
  minutes.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(
        %{auction_id: auction_id, amount: amount, max_price: max_price} = request,
        address,
        opts
      ) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <-
           current_wallet(address, actor, %{source_context: Keyword.get(opts, :context)}),
         {:ok, auction} <- auction(auction_id),
         :ok <- verified_treasury(auction),
         {:ok, auction_address} <- normalize(auction.auction_address),
         {:ok, max_price_q96} <-
           refusable(price_q96(max_price, auction.quote_token_decimals)),
         {:ok, snapshot} <- snapshot(auction_address, signer, max_price_q96),
         {:ok, max_price_q96} <- refusable(Autolaunch.BidPrice.align(max_price_q96, snapshot)),
         :ok <- bound_currency(snapshot, auction),
         :ok <- bounded_predecessor(snapshot, max_price_q96) do
      bid = %{
        auction: auction,
        auction_address: auction_address,
        signer: signer,
        max_price_q96: max_price_q96,
        snapshot: snapshot
      }

      if request[:pay_with] == "USDC",
        do: usdc_bid(bid, amount),
        else: currency_bid(bid, amount)
    end
  end

  @doc """
  What a confirmed step of a bid placed, read from its receipt's logs: the
  on-chain bid id and the amount it committed in the auction's currency, or
  `nil` for an approval, or for logs that do not record this very bid.
  """
  @spec result(map(), String.t(), [map()]) :: map() | nil
  def result(context, "bid", logs) do
    with {:ok, config} <- Lab.current(),
         {:ok, {[bid_id, owner_word], [price, amount]}} <-
           LabAbi.event_words(
             Lab.abi!(config, :auction),
             "BidSubmitted(uint256,address,uint256,uint128)",
             logs,
             context.auction_address
           ),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(owner, context.signer),
         true <- price == context.max_price_q96 and amount == context.amount_atomic do
      placed(context, bid_id, amount)
    else
      _not_this_bid -> nil
    end
  end

  # Only the adapter's own `StockBidPlaced` for this auction and this owner
  # records a USDC bid; its bid id and committed stock are read from it.
  def result(context, "usdc_bid", logs) do
    with {:ok, stocks} <- StocksLab.current(),
         {:ok, {[auction_word, owner_word, bid_id], [usdc_spent, stock_committed, price]}} <-
           LabAbi.event_words(
             StocksLab.abi!(stocks, :bid_adapter),
             StocksLabAbi.bid_placed_signature(),
             logs,
             context.adapter
           ),
         {:ok, auction} <- Abi.word_address(auction_word),
         {:ok, owner} <- Abi.word_address(owner_word),
         true <- Address.equal?(auction, context.auction_address),
         true <- Address.equal?(owner, context.signer),
         true <- price == context.max_price_q96 and usdc_spent == context.usdc_atomic do
      placed(context, bid_id, stock_committed)
    else
      _not_this_bid -> nil
    end
  end

  def result(_context, _approval, _logs), do: nil

  defp placed(context, bid_id, committed),
    do: %{
      "onchain_bid_id" => Integer.to_string(bid_id),
      "amount" => units(committed, context.currency_decimals)
    }

  # Reviews

  defp currency_bid(bid, typed) do
    %{auction: auction, auction_address: address, signer: signer, snapshot: snapshot} = bid

    with {:ok, amount} <- refusable(atomic_amount(typed, auction.quote_token_decimals)),
         :ok <- affordable(snapshot, amount),
         {:ok, config} <- lab(Lab) do
      expiration = DateTime.to_unix(DateTime.utc_now()) + @permit2_seconds

      data =
        LabAbi.encode(
          Lab.abi!(config, :auction),
          "submitBid(uint256,uint128,address,uint256,bytes)",
          [bid.max_price_q96, amount, signer, snapshot.prev_tick_price_q96, "0x"]
        )

      steps =
        token_approval(config, snapshot, amount) ++
          permit2_approval(config, snapshot, amount, expiration) ++
          [Review.step("bid", address, data)]

      {:ok,
       %{
         chain: Client.chain(config),
         steps: steps,
         facts:
           facts(
             bid,
             units(amount, auction.quote_token_decimals),
             auction.quote_token_symbol,
             nil
           ),
         context:
           context(bid, %{
             currency_symbol: auction.quote_token_symbol,
             amount_atomic: amount
           })
       }}
    end
  end

  defp usdc_bid(%{auction: auction, snapshot: snapshot, signer: signer} = bid, typed) do
    with :ok <- stocks_auction(auction),
         {:ok, usdc_amount} <- refusable(atomic_amount(typed, @usdc_decimals)),
         {:ok, usdc} <- usdc_snapshot(snapshot.currency, signer, usdc_amount),
         :ok <- usdc_affordable(usdc, usdc_amount),
         {:ok, min_stock_out} <- min_stock_out(usdc.stock_quote),
         {:ok, config} <- lab(StocksLab) do
      deadline = DateTime.to_unix(DateTime.utc_now()) + @usdc_deadline_seconds

      data =
        LabAbi.encode(
          StocksLab.abi!(config, :bid_adapter),
          "bidWithUsdc(address,uint256,uint128,uint256,uint256,uint256)",
          [
            bid.auction_address,
            usdc_amount,
            min_stock_out,
            bid.max_price_q96,
            snapshot.prev_tick_price_q96,
            deadline
          ]
        )

      steps =
        usdc_approval(config, usdc, usdc_amount) ++
          [Review.step("usdc_bid", usdc.adapter, data)]

      {:ok,
       %{
         chain: Client.chain(config),
         steps: steps,
         facts:
           facts(
             bid,
             units(usdc_amount, @usdc_decimals),
             "USDC",
             units(min_stock_out, auction.quote_token_decimals)
           ),
         context:
           context(bid, %{
             currency_symbol: "USDC",
             adapter: usdc.adapter,
             usdc_atomic: usdc_amount
           })
       }}
    end
  end

  # What the page shows beside the button: what the bid spends, the most it
  # pays per token and, for a USDC bid, the least stock the USDC must buy.
  defp facts(%{auction: auction, max_price_q96: max_price_q96}, pay, pay_symbol, min_stock_out),
    do: %{
      pay: pay,
      pay_symbol: pay_symbol,
      max_price: price_decimal(max_price_q96, auction.quote_token_decimals),
      currency_symbol: auction.quote_token_symbol,
      token_symbol: auction.token_symbol,
      min_stock_out: min_stock_out
    }

  defp context(bid, fields),
    do:
      Map.merge(
        %{
          auction_id: bid.auction.id,
          auction_address: bid.auction_address,
          signer: bid.signer,
          max_price_q96: bid.max_price_q96,
          max_price: price_decimal(bid.max_price_q96, bid.auction.quote_token_decimals),
          currency_decimals: bid.auction.quote_token_decimals
        },
        fields
      )

  defp usdc_approval(_config, %{usdc_allowance: allowance}, amount) when allowance >= amount,
    do: []

  defp usdc_approval(config, usdc, amount),
    do: [
      Review.step(
        "usdc_approval",
        usdc.usdc,
        LabAbi.encode(StocksLab.abi!(config, :erc20), "approve(address,uint256)", [
          usdc.adapter,
          amount
        ])
      )
    ]

  defp usdc_snapshot(stock, signer, usdc_amount) do
    case LabBidChainClient.usdc_snapshot(%{
           stock: stock,
           signer: signer,
           usdc_amount: usdc_amount
         }) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp usdc_affordable(%{usdc_balance: balance}, amount) when balance >= amount, do: :ok
  defp usdc_affordable(_usdc, _amount), do: unavailable(:amount_above_balance)

  defp min_stock_out(quote) when quote > 0 do
    minimum = quote - div(quote * @usdc_tolerance_bps, 10_000)
    if minimum in 1..@uint128_max, do: {:ok, minimum}, else: unavailable(:usdc_route_unavailable)
  end

  defp min_stock_out(_quote), do: unavailable(:usdc_route_unavailable)

  defp stocks_auction(%{kind: :stocks}), do: :ok
  defp stocks_auction(_auction), do: unavailable(:usdc_bids_unavailable)

  # Only the transactions this wallet still needs. An allowance that already
  # covers the amount and outlives the next ten minutes is spent as it stands.
  defp token_approval(_config, %{token_allowance: allowance}, amount) when allowance >= amount,
    do: []

  defp token_approval(config, snapshot, amount),
    do: [
      Review.step(
        "token_approval",
        snapshot.currency,
        LabAbi.encode(Lab.abi!(config, :token), "approve(address,uint256)", [
          snapshot.permit2,
          amount
        ])
      )
    ]

  defp permit2_approval(config, snapshot, amount, expiration) do
    if permit2_current?(snapshot, amount),
      do: [],
      else: [
        Review.step(
          "permit2_approval",
          snapshot.permit2,
          LabAbi.encode(
            Lab.abi!(config, :permit2),
            "approve(address,address,uint160,uint48)",
            [snapshot.currency, snapshot.auction, amount, expiration]
          )
        )
      ]
  end

  # Its expiry stays a plain integer: a canonical `uint48` maximum is a
  # perfectly good allowance and no calendar can hold it.
  defp permit2_current?(%{permit2_amount: allowed, permit2_expiration: expires}, amount),
    do: allowed >= amount and expires >= DateTime.to_unix(DateTime.utc_now()) + @reuse_seconds

  defp lab(module) do
    case module.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:bid_preparation_unavailable)
    end
  end

  # Session and wallet identity

  defp human(opts) do
    case Keyword.get(opts, :actor) do
      %Human{} = actor -> {:ok, actor}
      _anonymous -> unavailable(:authentication_required)
    end
  end

  @doc "The mounted lease an Ash action context carries, or the refusal to read for it."
  @spec lease(map()) :: {:ok, map()} | {:error, term()}
  def lease(%{source_context: %{session_lease: %{lineage: lineage, account_id: account_id}}})
      when is_binary(lineage) and is_integer(account_id),
      do: {:ok, %{lineage: lineage, account_id: account_id}}

  def lease(_context), do: unavailable(:session_lease_required)

  # The wallet has to be one the leased account links, read now: never a guess.
  defp current_wallet(address, actor, context) do
    with {:ok, signer} <- normalize(address),
         {:ok, lease} <- lease(context),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         do: linked_wallet(account, signer)
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  # The lease and the acting human have to name one account.
  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  defp linked_wallet(%{wallet_addresses: wallets}, signer) when is_list(wallets) do
    if Enum.any?(wallets, &Address.equal?(&1, signer)),
      do: {:ok, signer},
      else: unavailable(:wrong_signer)
  end

  # Chain snapshot

  defp snapshot(address, signer, max_price_q96) do
    case ChainClient.module().snapshot(%{
           auction: address,
           signer: signer,
           max_price_q96: max_price_q96
         }) do
      {:ok, snapshot} -> {:ok, Map.put(snapshot, :auction, address)}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # The auction's own currency has to be the one this site recorded for it, so
  # an amount is never read in one token and spent in another.
  defp bound_currency(%{currency: currency}, %{quote_token_address: recorded}) do
    if Address.equal?(currency, recorded),
      do: :ok,
      else: unavailable(:auction_currency_changed)
  end

  # The predecessor tick is the one argument no reviewed production source
  # supplies yet, so it has to be a word the auction could really hold below
  # this bid's own price, and it has to come from a source that names itself.
  defp bounded_predecessor(%{prev_tick_price_q96: hint} = snapshot, max_price_q96)
       when hint in 0..@uint256_max and hint < max_price_q96,
       do: reviewed_source(snapshot)

  defp bounded_predecessor(_snapshot, _max_price_q96),
    do: unavailable(:bid_preparation_unavailable)

  defp reviewed_source(%{predecessor_source: source}) when is_binary(source) and source != "",
    do: :ok

  defp reviewed_source(_unnamed), do: unavailable(:bid_preparation_unavailable)

  defp affordable(%{currency_balance: balance}, amount) when balance >= amount, do: :ok
  defp affordable(_snapshot, _amount), do: unavailable(:amount_above_balance)

  # Stored auctions

  defp auction(auction_id) do
    case Autolaunch.get_public_auction(auction_id, actor: nil) do
      {:ok, nil} -> unavailable(:auction_not_found)
      result -> result
    end
  end

  # Only an id can name an auction, so anything else is simply not found; a
  # read that fails for a real id is the database's, not the caller's.
  defp quoted_auction(auction_id, opts) do
    with {:ok, id} when is_binary(id) <- Ash.Type.UUID.cast_input(auction_id, []),
         {:ok, %Autolaunch.Auction{} = auction} <-
           Autolaunch.get_public_auction(id, Keyword.put(opts, :actor, nil)) do
      {:ok, auction}
    else
      {:error, %{}} -> {:error, :database_unavailable}
      _not_found -> {:error, :auction_not_found}
    end
  end

  # The auction must raise for the treasury this site recorded for it: a
  # verified report on Base, the admitted launchpad for a Base memestock
  # auction, and the recorded addresses on a local fork.
  defp verified_treasury(auction) do
    cond do
      Lab.test_chain?() -> lab_treasury(auction)
      auction.kind == :stocks -> launchpad_treasury(auction)
      true -> verified_production_treasury(auction)
    end
  end

  defp launchpad_treasury(%{treasury_address: treasury_address}) do
    with {:ok, launchpad} <- admitted_launchpad() do
      if Address.equal?(treasury_address, launchpad),
        do: :ok,
        else: unavailable(:treasury_security_changed)
    end
  end

  defp admitted_launchpad do
    case StocksLab.current() do
      {:ok, config} -> normalize(StocksLab.address!(config, :launchpad))
      {:error, _reason} -> unavailable(:bid_preparation_unavailable)
    end
  end

  defp lab_treasury(%{treasury_address: treasury_address}) do
    with {:ok, _treasury} <- normalize(treasury_address), do: :ok
  end

  defp verified_production_treasury(%{treasury_security_report: nil}),
    do: unavailable(:treasury_report_missing)

  defp verified_production_treasury(%{treasury_security_report: %Ash.NotLoaded{}}),
    do: unavailable(:treasury_report_missing)

  defp verified_production_treasury(%{
         treasury_address: address,
         treasury_security_report: %{address: address} = report
       }) do
    with {:ok, _report} <- TreasurySecurity.revalidate_bound(report), do: :ok
  end

  defp verified_production_treasury(_auction), do: unavailable(:treasury_security_changed)

  # Amounts and prices

  @doc """
  The one bid-amount language: exact decimal digits, at most `decimals` places
  of the auction's own currency.

  The form validates against this, so the page never invites an amount that
  preparation would refuse.
  """
  @spec atomic_amount(term(), non_neg_integer()) :: {:ok, pos_integer()} | {:error, atom()}
  def atomic_amount(value, decimals) when is_binary(value) and is_integer(decimals) do
    value = String.trim(value)

    with true <- String.match?(value, ~r/^\d+(?:\.\d{1,#{decimals}})?$/),
         {decimal, ""} <- Decimal.parse(value),
         scaled <- Decimal.mult(decimal, Decimal.new(Integer.pow(10, decimals))),
         rounded <- Decimal.round(scaled, 0),
         :eq <- Decimal.compare(scaled, rounded),
         amount when amount in 1..@uint128_max <- Decimal.to_integer(rounded) do
      {:ok, amount}
    else
      _refused -> {:error, :invalid_amount}
    end
  end

  def atomic_amount(_value, _decimals), do: {:error, :invalid_amount}

  @doc "The exact decimal rendering of an atomic currency amount, never rounded up."
  @spec units(non_neg_integer(), non_neg_integer()) :: String.t()
  def units(amount, decimals), do: Rpc.format_units(amount, decimals)

  @doc """
  The exact Q96 price a decimal maximum price names, in currency base units per
  NEW base unit: `price * 10^currency_decimals / 10^18`, scaled by 2^96.
  """
  @spec price_q96(term(), non_neg_integer()) :: {:ok, pos_integer()} | {:error, atom()}
  def price_q96(value, currency_decimals)
      when is_binary(value) and is_integer(currency_decimals) do
    value = String.trim(value)

    with true <- byte_size(value) <= 100 and String.match?(value, ~r/^(?:\d+(?:\.\d+)?|\.\d+)\z/),
         [whole | fraction] <- String.split(value, "."),
         fraction <- List.first(fraction) || "",
         numerator when numerator > 0 <- String.to_integer(whole <> fraction) do
      scaled = numerator * @q96 * Integer.pow(10, currency_decimals)
      quotient = div(scaled, Integer.pow(10, byte_size(fraction) + @new_decimals))
      if quotient in 1..@uint256_max, do: {:ok, quotient}, else: {:error, :invalid_price}
    else
      _ -> {:error, :invalid_decimal}
    end
  end

  def price_q96(_, _), do: {:error, :invalid_decimal}

  defp price_decimal(q96, currency_decimals),
    do: Autolaunch.BidPrice.decimal(q96, currency_decimals)

  defp positive_decimal(value, refusal) when is_binary(value) do
    value = String.trim(value)

    with true <- byte_size(value) <= 100,
         true <- String.match?(value, ~r/^(?:\d+(?:\.\d+)?|\.\d+)$/),
         {decimal, ""} <- Decimal.parse(value),
         :gt <- Decimal.compare(decimal, 0) do
      {:ok, decimal}
    else
      _refused -> {:error, refusal}
    end
  end

  defp positive_decimal(_value, refusal), do: {:error, refusal}

  defp nonnegative_decimal_or_zero(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} ->
        if Decimal.compare(decimal, 0) in [:eq, :gt], do: decimal, else: Decimal.new(0)

      _unreadable ->
        Decimal.new(0)
    end
  end

  defp nonnegative_decimal_or_zero(_value), do: Decimal.new(0)

  defp decimal_string(decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp status_band(false, _max_price, _projected_price), do: "inactive"

  defp status_band(true, max_price, projected_price) do
    if Decimal.equal?(max_price, projected_price), do: "borderline", else: "active"
  end

  defp quote_warnings(auction, active?) do
    []
    |> maybe_warning(not active?, "max_price_below_current_clearing_price")
    |> maybe_warning(auction.state != :active, "auction_not_biddable")
  end

  defp maybe_warning(warnings, true, warning), do: [warning | warnings]
  defp maybe_warning(warnings, false, _warning), do: warnings

  # Shared helpers

  defp normalize(value) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(:invalid_address)
    end
  end

  # The form asks the amount and price helpers the same question the page does,
  # so their plain answers become the one typed refusal here.
  defp refusable({:error, reason}), do: unavailable(reason)
  defp refusable(result), do: result

  # A typed Ash error, so the refusal survives the action's error class and the
  # presenter can name the fact that actually stopped the bid.
  defp unavailable(reason),
    do:
      {:error,
       Ash.Error.Invalid.Unavailable.exception(resource: Autolaunch.Auction, reason: reason)}
end
