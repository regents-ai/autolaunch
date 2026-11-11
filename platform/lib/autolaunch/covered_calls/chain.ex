defmodule Autolaunch.CoveredCalls.Chain do
  @moduledoc """
  What a `CoveredCallsV2` contract and its stock say at one block. Covered calls
  keep no records of their own: every listing, bid, holding and balance a page
  or an agent sees is read here from the contract, so it matches the chain after
  any reload.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Lab
  alias RegentChain.Call

  # Each kind of record the contract numbers from 1: how many there are, one
  # by its id, and the words it comes back as.
  @records %{
    listing: {"listingCount()", "listings(uint256)", 10, :unknown_listing},
    bid: {"bidCount()", "bids(uint256)", 8, :unknown_bid}
  }
  # Listings, bids and a wallet's positions are read a few at a time, so a
  # market with many weeks of them still answers in a few round trips.
  @read_concurrency 8
  @read_timeout 20_000
  @wad 1_000_000_000_000_000_000

  @type listing :: %{
          id: pos_integer(),
          seller: String.t(),
          expiry: non_neg_integer(),
          stock_returned: boolean(),
          amount: non_neg_integer(),
          filled: non_neg_integer(),
          exercised: non_neg_integer(),
          strike_per_token: non_neg_integer(),
          premium_per_token: non_neg_integer(),
          strike_paid: non_neg_integer(),
          strike_collected: non_neg_integer()
        }

  @type bid :: %{
          id: pos_integer(),
          bidder: String.t(),
          expiry: non_neg_integer(),
          amount: non_neg_integer(),
          filled: non_neg_integer(),
          strike_per_token: non_neg_integer(),
          premium_per_token: non_neg_integer(),
          min_sale: non_neg_integer(),
          refund_due: non_neg_integer()
        }

  @doc "The read options and latest block of the Base deployment covered calls run on."
  def latest(lab) do
    opts = Lab.rpc_opts(lab, "autolaunch covered calls")
    with {:ok, block} <- Rpc.latest_block(opts), do: {:ok, block, opts}
  end

  @doc """
  Every listing and bid on `market`'s contract, the stock's multiplier and any
  scheduled change to it, and the reference price, at `block`.
  """
  def book(market, block, opts) do
    with {:ok, listings} <- all(market, :listing, block, opts),
         {:ok, bids} <- all(market, :bid, block, opts),
         {:ok, multiplier} <-
           Rpc.call_uint(market.stock, Call.encode("multiplier()", []), block, opts),
         {:ok, effective_at} <-
           Rpc.call_uint(market.stock, Call.encode("effectiveAt()", []), block, opts),
         {:ok, unit} <- unit(market, block, opts) do
      {:ok,
       %{
         block: block.number,
         now: block.timestamp,
         unit: unit,
         multiplier: multiplier,
         effective_at: effective_at,
         price: price(market, block, opts),
         listings: listings,
         bids: bids
       }}
    end
  end

  @doc "What `wallet` holds on each listing: calls it may exercise and stock it may claim."
  def holdings(market, listings, wallet, block, opts) do
    with {:ok, positions} <- each(listings, &holding(market, &1, wallet, block, opts)),
         do: {:ok, Enum.reject(positions, &match?(%{held: 0, claimable: 0}, &1))}
  end

  defp holding(market, listing, wallet, block, opts) do
    with {:ok, position} <- position(market, listing.id, wallet, block, opts),
         do: {:ok, Map.put(position, :listing_id, listing.id)}
  end

  @doc """
  One listing at `block`, or `:unknown_listing` when the contract has none by
  that id (ids count from 1 to `listingCount`; the contract refuses any other).
  """
  def listing(market, id, block, opts), do: one(market, :listing, id, block, opts)

  @doc """
  One bid at `block`, or `:unknown_bid` when the contract has none by that id
  (ids count from 1 to `bidCount`; the contract refuses any other).
  """
  def bid(market, id, block, opts), do: one(market, :bid, id, block, opts)

  @doc "All the USDC `refundBid` would send bid `id`'s bidder at `block` (`refundable`)."
  def refundable(market, id, block, opts),
    do: uint(market.contract, "refundable(uint256)", [id], block, opts)

  @doc "`wallet`'s own bids among `bids`, each with what `refundBid` would send it at `block`."
  def own_bids(market, bids, wallet, block, opts) do
    bids
    |> Enum.filter(&(&1.bidder == wallet))
    |> each(fn bid ->
      with {:ok, refundable} <- refundable(market, bid.id, block, opts),
           do: {:ok, Map.put(bid, :refundable, refundable)}
    end)
  end

  @doc "What `wallet` may exercise and claim on listing `id`, at `block`."
  def position(market, id, wallet, block, opts) do
    with {:ok, held} <- uint(market.contract, "held(uint256,address)", [id, wallet], block, opts),
         {:ok, claimable} <-
           uint(market.contract, "claimable(uint256,address)", [id, wallet], block, opts),
         do: {:ok, %{held: held, claimable: claimable}}
  end

  @doc "The stock's scheduled multiplier change time, as the contract checks it."
  def effective_at(market, block, opts),
    do: Rpc.call_uint(market.stock, Call.encode("effectiveAt()", []), block, opts)

  @doc "The USDC the contract takes premiums and strikes in."
  def usdc(market, block, opts) do
    with {:ok, token} <- Rpc.call_address(market.contract, Call.encode("usdc()", []), block, opts),
         do: {:ok, String.downcase(token)}
  end

  @doc "The contract's raw units in one whole stock token."
  def unit(market, block, opts),
    do: Rpc.call_uint(market.contract, Call.encode("unit()", []), block, opts)

  @doc "A wallet's balance of `token` at `block`."
  def balance(token, wallet, block, opts),
    do: Rpc.call_uint(token, Abi.encode_erc20("balance_of", [wallet]), block, opts)

  @doc "A wallet's balance of `token` and what it lets `spender` take, at `block`."
  def funds(token, wallet, spender, block, opts) do
    with {:ok, balance} <- balance(token, wallet, block, opts),
         {:ok, allowance} <-
           Rpc.call_uint(token, Abi.encode_erc20("allowance", [wallet, spender]), block, opts) do
      {:ok, %{balance: balance, allowance: allowance}}
    end
  end

  @doc "A raw stock amount as the shares it is worth at `multiplier` (WAD)."
  def shares(raw, multiplier), do: div(raw * multiplier, @wad)

  defp all(market, kind, block, opts) do
    {counter, _record, _words, _unknown} = Map.fetch!(@records, kind)

    with {:ok, count} <- uint(market.contract, counter, [], block, opts),
         do: each(1..count//1, &record(market, kind, &1, block, opts))
  end

  defp one(market, kind, id, block, opts) do
    {counter, _record, _words, unknown} = Map.fetch!(@records, kind)

    with {:ok, count} <- uint(market.contract, counter, [], block, opts),
         true <- id <= count || {:error, unknown},
         do: record(market, kind, id, block, opts)
  end

  defp record(market, kind, id, block, opts) do
    {_count, record, words, _unknown} = Map.fetch!(@records, kind)

    with {:ok, words} <-
           Rpc.call_words(market.contract, Call.encode(record, [id]), block, words, opts),
         do: {:ok, decode(kind, id, words)}
  end

  # One read per item, a few at a time, in order. The first that fails fails
  # them all: a book or a portfolio missing a listing would be wrong, not short.
  defp each(items, read) do
    items
    |> Task.async_stream(read,
      max_concurrency: @read_concurrency,
      timeout: @read_timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, value}}, {:ok, kept} -> {:cont, {:ok, [value | kept]}}
      {:ok, {:error, _reason} = error}, _kept -> {:halt, error}
      {:exit, _reason}, _kept -> {:halt, {:error, :chain_unavailable}}
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end

  defp decode(:listing, id, [
         seller,
         expiry,
         returned,
         amount,
         filled,
         exercised,
         strike,
         premium,
         paid,
         collected
       ]) do
    %{
      id: id,
      seller: word_address(seller),
      expiry: expiry,
      stock_returned: returned == 1,
      amount: amount,
      filled: filled,
      exercised: exercised,
      strike_per_token: strike,
      premium_per_token: premium,
      strike_paid: paid,
      strike_collected: collected
    }
  end

  defp decode(:bid, id, [bidder, expiry, amount, filled, strike, premium, min_sale, refund_due]) do
    %{
      id: id,
      bidder: word_address(bidder),
      expiry: expiry,
      amount: amount,
      filled: filled,
      strike_per_token: strike,
      premium_per_token: premium,
      min_sale: min_sale,
      refund_due: refund_due
    }
  end

  # The Chainlink reference price (8 decimals) and when it was last updated, or
  # nil when the feed does not answer: a missing price hides the suggested
  # premium and never stops a listing.
  defp price(market, block, opts) do
    case Rpc.call_words(market.feed, Call.encode("latestRoundData()", []), block, 5, opts) do
      {:ok, [_round, answer, _started, updated_at, _answered]} when answer > 0 ->
        %{answer: answer, decimals: 8, updated_at: updated_at}

      _unavailable ->
        nil
    end
  end

  defp uint(contract, signature, arguments, block, opts),
    do: Rpc.call_uint(contract, Call.encode(signature, arguments), block, opts)

  defp word_address(word),
    do:
      "0x" <> (word |> Integer.to_string(16) |> String.pad_leading(40, "0") |> String.downcase())
end
