defmodule Autolaunch.CoveredCalls.Chain do
  @moduledoc """
  What a `CoveredCallsV2` contract and its stock say at one block. Covered calls
  keep no records of their own: every listing, bid, holding and balance a page
  or an agent sees is read here from the contract, so it matches the chain after
  any reload.

  Listings, bids and a wallet's place on them are read through
  `Autolaunch.Chain.Multicall`, about two hundred to a request, never one
  request each: anyone with USDC can post bids, so the count of them is not the
  site's to bound.
  """

  alias Autolaunch.Chain.{Abi, Multicall, Rpc}
  alias Autolaunch.CoveredCalls.Terms
  alias Autolaunch.Lab
  alias RegentChain.Call

  # Each kind of record the contract numbers from 1: how many there are, one
  # by its id, and the words it comes back as.
  @records %{
    listing: {"listingCount()", "listings(uint256)", 10, :unknown_listing},
    bid: {"bidCount()", "bids(uint256)", 8, :unknown_bid}
  }
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
  The listings and bids on `market`'s contract that `settled?` does not already
  hold, the stock's multiplier and any scheduled change to it, and the
  reference price, at `block`. `settled?` is asked for each kind and id
  (`Autolaunch.CoveredCalls.Book.settled?/3`); left out, every record is read.
  """
  def book(market, block, opts, settled? \\ fn _kind, _id -> false end) do
    with {:ok, heads} <- heads(market, block, opts),
         {:ok, listings} <-
           records(market, :listing, unsettled(:listing, heads.listings, settled?), block, opts),
         {:ok, bids} <- records(market, :bid, unsettled(:bid, heads.bids, settled?), block, opts) do
      {:ok,
       heads
       |> Map.take([:unit, :multiplier, :effective_at, :price])
       |> Map.merge(%{
         block: block.number,
         now: block.timestamp,
         listings: listings,
         bids: bids
       })}
    end
  end

  defp unsettled(kind, count, settled?),
    do: for(id <- 1..count//1, not settled?.(kind, id), do: id)

  # How many listings and bids there are, the contract's unit, the stock's
  # multiplier and scheduled change, and the reference price, in one request.
  defp heads(market, block, opts) do
    reads =
      for(
        {contract, signature} <- [
          {market.contract, "listingCount()"},
          {market.contract, "bidCount()"},
          {market.contract, "unit()"},
          {market.stock, "multiplier()"},
          {market.stock, "effectiveAt()"},
          {market.feed, "latestRoundData()"}
        ],
        do: {contract, Call.encode(signature, [])}
      )

    with {:ok, [listings, bids, unit, multiplier, effective_at, price]} <-
           Multicall.read(reads, block, opts),
         {:ok, [listings, bids, unit, multiplier, effective_at]} <-
           each([listings, bids, unit, multiplier, effective_at], &amount/1) do
      {:ok,
       %{
         listings: listings,
         bids: bids,
         unit: unit,
         multiplier: multiplier,
         effective_at: effective_at,
         price: price(price)
       }}
    end
  end

  @doc "The listings or bids (`kind`) numbered `ids` on `market`'s contract at `block`, in that order."
  def records(market, kind, ids, block, opts) do
    {_counter, signature, count, _unknown} = Map.fetch!(@records, kind)
    reads = Enum.map(ids, &{market.contract, Call.encode(signature, [&1])})

    with {:ok, answers} <- Multicall.read(reads, block, opts),
         do: ids |> Enum.zip(answers) |> each(&answered(kind, &1, count))
  end

  defp answered(kind, {id, answer}, count) do
    with {:ok, words} <- words(answer, count), do: {:ok, decode(kind, id, words)}
  end

  @doc """
  What `wallet` has on each of `listings` at `block`, leaving out those it has
  nothing on. Only what can be there is asked for: calls to exercise (`held`)
  until four weeks after the window closes, when lapsed calls leave the
  portfolio, and stock to claim (`claimable`) where `wallet` is the seller or
  some of the listing has been exercised.
  """
  def holdings(market, listings, wallet, block, opts) do
    asks =
      for listing <- listings,
          view <- views(listing, wallet, block.timestamp),
          do: {listing, view}

    reads =
      for {listing, view} <- asks,
          do: {market.contract, Call.encode("#{view}(uint256,address)", [listing.id, wallet])}

    with {:ok, answers} <- Multicall.read(reads, block, opts),
         {:ok, amounts} <- each(answers, &amount/1) do
      {:ok,
       asks
       |> Enum.zip(amounts)
       |> Enum.group_by(fn {{listing, _view}, _amount} -> listing.id end, fn
         {{_listing, view}, amount} -> {view, amount}
       end)
       |> Enum.map(fn {id, amounts} ->
         Map.merge(%{listing_id: id, held: 0, claimable: 0}, Map.new(amounts))
       end)
       |> Enum.reject(&match?(%{held: 0, claimable: 0}, &1))
       |> Enum.sort_by(& &1.listing_id)}
    end
  end

  defp views(listing, wallet, now) do
    held = if now < listing.expiry + Terms.exercise_window() + Terms.lapsed_shown(), do: [:held]

    claimable =
      if listing.seller == wallet or listing.exercised > 0, do: [:claimable]

    List.wrap(held) ++ List.wrap(claimable)
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

  @doc "Each of `bids` with what `refundBid` would send its bidder at `block` (`refundable`)."
  def refundables(market, bids, block, opts) do
    reads =
      Enum.map(bids, &{market.contract, Call.encode("refundable(uint256)", [&1.id])})

    with {:ok, answers} <- Multicall.read(reads, block, opts),
         {:ok, amounts} <- each(answers, &amount/1) do
      {:ok, Enum.zip_with(bids, amounts, &Map.put(&1, :refundable, &2))}
    end
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

  # Each item through `read`, in order. The first that fails fails them all: a
  # book or a portfolio missing a listing would be wrong, not short.
  defp each(items, read) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, kept} ->
      case read.(item) do
        {:ok, value} -> {:cont, {:ok, [value | kept]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end

  # A read's answer as `count` words. A read the contract refused, or an
  # answer of another size (an address with no contract answers nothing), is
  # no reading of the chain.
  defp words(answer, count) when is_binary(answer) and byte_size(answer) == count * 32,
    do: {:ok, for(<<word::256 <- answer>>, do: word)}

  defp words(:reverted, _count), do: {:error, :chain_unavailable}
  defp words(_answer, _count), do: {:error, :invalid_chain_response}

  defp amount(answer) do
    with {:ok, [amount]} <- words(answer, 1), do: {:ok, amount}
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
  defp price(answer) do
    case words(answer, 5) do
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
