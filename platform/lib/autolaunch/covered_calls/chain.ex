defmodule Autolaunch.CoveredCalls.Chain do
  @moduledoc """
  What a `CoveredCallsV1` contract and its stock say at one block. Covered calls
  keep no records of their own: every listing, holding and balance a page or an
  agent sees is read here from the contract, so it matches the chain after any
  reload.
  """

  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Lab
  alias RegentChain.Call

  @listing_words 10
  # Listings and a wallet's positions are read a few at a time, so a market
  # with many weeks of listings still answers in a few round trips.
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

  @doc "The read options and latest block of the Base deployment covered calls run on."
  def latest(lab) do
    opts = Lab.rpc_opts(lab, "autolaunch covered calls")
    with {:ok, block} <- Rpc.latest_block(opts), do: {:ok, block, opts}
  end

  @doc """
  Every listing on `market`'s contract, the stock's multiplier and any scheduled
  change to it, and the reference price, at `block`.
  """
  def book(market, block, opts) do
    with {:ok, count} <-
           Rpc.call_uint(market.contract, Call.encode("listingCount()", []), block, opts),
         {:ok, listings} <- listings(market.contract, count, block, opts),
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
         listings: listings
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
  def listing(market, id, block, opts) do
    with {:ok, count} <-
           Rpc.call_uint(market.contract, Call.encode("listingCount()", []), block, opts),
         true <- id <= count || {:error, :unknown_listing},
         {:ok, words} <-
           Rpc.call_words(
             market.contract,
             Call.encode("listings(uint256)", [id]),
             block,
             @listing_words,
             opts
           ),
         do: {:ok, listing(id, words)}
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

  @doc "A wallet's balance of `token` and what it lets `spender` take, at `block`."
  def funds(token, wallet, spender, block, opts) do
    with {:ok, balance} <-
           Rpc.call_uint(token, Abi.encode_erc20("balance_of", [wallet]), block, opts),
         {:ok, allowance} <-
           Rpc.call_uint(token, Abi.encode_erc20("allowance", [wallet, spender]), block, opts) do
      {:ok, %{balance: balance, allowance: allowance}}
    end
  end

  @doc "A raw stock amount as the shares it is worth at `multiplier` (WAD)."
  def shares(raw, multiplier), do: div(raw * multiplier, @wad)

  defp listings(_contract, 0, _block, _opts), do: {:ok, []}

  defp listings(contract, count, block, opts) do
    each(1..count, fn id ->
      with {:ok, words} <-
             Rpc.call_words(
               contract,
               Call.encode("listings(uint256)", [id]),
               block,
               @listing_words,
               opts
             ),
           do: {:ok, listing(id, words)}
    end)
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

  defp listing(id, [
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
