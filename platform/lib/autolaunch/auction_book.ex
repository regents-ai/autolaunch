defmodule Autolaunch.AuctionBook do
  @moduledoc """
  What a bidder needs to see in an open auction, read from the auction
  contract each time a page asks: the price everyone pays right now, the
  lowest maximum a new bid can use to get tokens, how much has been bid at
  each maximum price, and how much of the supply has sold.

  The price is the one the auction would record in this block, from a call to
  `checkpoint()` that is never sent, so it counts bids the auction has not
  recorded a price for yet. A new bid's maximum has to sit on the auction's
  price grid and above that price, so the lowest one that gets tokens is the
  next grid step above it.

  Every maximum price comes from the auction's `BidSubmitted` logs. A bid whose
  maximum is above the price buys at the price every block; a bid exactly at
  it shares what the higher bids leave; a bid below it has stopped buying.
  """

  alias Autolaunch.{BidActions, BidPrice}
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Lab
  alias Autolaunch.LabAbi
  alias Autolaunch.LabRpc
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @bid_submitted "BidSubmitted(uint256,address,uint256,uint128)"

  # The ladder shows the prices nearest the auction price: this many above it,
  # and this many below.
  @above 7
  @below 3

  @type standing :: :in | :sharing | :outbid
  @type level :: %{
          price: String.t(),
          price_q96: pos_integer(),
          amount: String.t(),
          bids: pos_integer(),
          standing: standing()
        }

  # Prices on screen keep this many significant digits: a price stored on the
  # auction's grid is a little under the round figure it was set from.
  @shown_digits 6

  @doc "A Base auction's book, read at the latest block."
  @spec base(map()) :: {:ok, map()} | {:error, atom()}
  def base(%{auction_address: address, quote_token_decimals: decimals} = auction)
      when is_binary(address) do
    with {:ok, opts} <- base_opts(auction),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, start} <- Rpc.call_uint(address, LabAbi.selector("startBlock()"), block, opts),
         do: read(address, decimals, start, block, opts)
  end

  def base(_auction), do: {:error, :no_auction_contract}

  @doc """
  A Robinhood auction's book, read at the latest block by its address alone:
  the auction names its currency, and the currency its decimals. Its contracts
  keep time by the rollup clock, not by the block numbers logs carry, so its
  logs are read from the chain's start.
  """
  @spec robinhood(String.t()) :: {:ok, map()} | {:error, atom()}
  def robinhood(address) when is_binary(address) do
    with {:ok, config} <- RobinhoodLab.current(),
         opts = RobinhoodLab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, currency} <- Rpc.call_uint(address, LabAbi.selector("currency()"), block, opts),
         {:ok, currency} <- Abi.word_address(currency),
         {:ok, decimals} <- Rpc.call_uint(currency, LabAbi.selector("decimals()"), block, opts) do
      read(address, decimals, 0, block, opts)
    else
      :error -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  @doc """
  Where a bid with this maximum stands against the book's price: buying every
  block, sharing at the price, or no longer buying.
  """
  @spec standing(non_neg_integer(), map()) :: standing()
  def standing(price_q96, %{clearing_q96: clearing}) when price_q96 > clearing, do: :in
  def standing(price_q96, %{clearing_q96: price_q96}), do: :sharing
  def standing(_price_q96, _book), do: :outbid

  @doc """
  What a bid of `amount` at a maximum of `max_price`, both as typed, can expect
  from this book: whether the maximum clears the price to beat, and if it does,
  the tokens it buys if the price stays where it is and the fewest it buys even
  if the price climbs to that maximum. Nil until the maximum reads as a price.
  """
  @spec outlook(String.t(), String.t(), map()) :: map() | nil
  def outlook(amount, max_price, %{price_to_beat_q96: to_beat, decimals: decimals} = book)
      when is_integer(to_beat) do
    case BidActions.price_q96(max_price, decimals) do
      {:ok, price_q96} when price_q96 >= to_beat ->
        %{
          reaches?: true,
          about: tokens(amount, plain(BidPrice.decimal(book.clearing_q96, decimals))),
          at_least: tokens(amount, plain(max_price))
        }

      {:ok, _below} ->
        %{reaches?: false}

      {:error, _unreadable} ->
        nil
    end
  end

  def outlook(_amount, _max_price, _book), do: nil

  # An amount typed as a plain decimal above zero buys amount / price tokens.
  defp tokens(amount, price) do
    amount = String.trim(amount)

    if String.match?(amount, ~r/\A\d+(?:\.\d+)?\z/) and Decimal.gt?(plain(amount), 0),
      do:
        amount
        |> plain()
        |> Decimal.div(price)
        |> Decimal.normalize()
        |> Decimal.to_string(:normal)
  end

  defp plain(typed), do: Decimal.new(String.trim(typed), max_digits: :infinity)

  defp read(address, decimals, from_block, block, opts) do
    with {:ok, floor} <- uint(address, "floorPrice()", block, opts),
         {:ok, spacing} <- uint(address, "tickSpacing()", block, opts),
         {:ok, cap} <- uint(address, "MAX_BID_PRICE()", block, opts),
         {:ok, supply} <- uint(address, "totalSupply()", block, opts),
         {:ok, cleared} <- uint(address, "totalCleared()", block, opts),
         {:ok, [clearing | _checkpoint]} <-
           Rpc.call_words(address, LabAbi.selector("checkpoint()"), block, 6, opts),
         {:ok, logs} <- logs(address, from_block, block, opts),
         {:ok, bids} <- bids(logs) do
      to_beat = (div(clearing, spacing) + 1) * spacing
      book = %{clearing_q96: clearing}

      {:ok,
       %{
         block: block,
         clearing_q96: clearing,
         clearing: shown(clearing, decimals),
         floor: shown(floor, decimals),
         decimals: decimals,
         price_to_beat_q96: if(to_beat <= cap, do: to_beat),
         price_to_beat: if(to_beat <= cap, do: entered(to_beat, spacing, decimals)),
         sold_percent: if(supply > 0, do: cleared * 100 / supply, else: 0.0),
         levels: levels(bids, decimals, book)
       }}
    end
  end

  defp uint(address, signature, block, opts),
    do: Rpc.call_uint(address, LabAbi.selector(signature), block, opts)

  # Each bid's maximum price and amount, in chain order.
  defp bids(logs) do
    Enum.reduce_while(logs, {:ok, []}, fn log, {:ok, found} ->
      with %{"removed" => false, "data" => "0x" <> data} <- log,
           [price, amount] <- words(data) do
        {:cont, {:ok, [{price, amount} | found]}}
      else
        _invalid -> {:halt, {:error, :invalid_chain_response}}
      end
    end)
  end

  defp words(hex), do: for(<<word::binary-size(64) <- hex>>, do: String.to_integer(word, 16))

  # The bids grouped by maximum price, highest first, trimmed to the prices
  # nearest the auction price with a count of the ones left out on each side.
  defp levels(bids, decimals, book) do
    {above, rest} =
      bids
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {price, amounts} ->
        %{
          price: shown(price, decimals),
          price_q96: price,
          amount: Rpc.format_units(Enum.sum(amounts), decimals),
          bids: length(amounts),
          standing: standing(price, book)
        }
      end)
      |> Enum.sort_by(& &1.price_q96, :desc)
      |> Enum.split_with(&(&1.standing == :in))

    {sharing, below} = Enum.split_with(rest, &(&1.standing == :sharing))

    %{
      shown: Enum.take(above, -@above) ++ sharing ++ Enum.take(below, @below),
      hidden_above: max(length(above) - @above, 0),
      hidden_below: max(length(below) - @below, 0)
    }
  end

  defp shown(q96, decimals), do: q96 |> exact(decimals) |> significant(@shown_digits, :half_up)

  # The shortest price a bidder can type that the bid form turns back into
  # exactly this grid price: rounded up, so it never falls to the grid step
  # below, with as few digits as keep it under the step above.
  defp entered(q96, spacing, decimals) do
    exact = exact(q96, decimals)

    Enum.find_value(Stream.iterate(1, &(&1 + 1)), fn digits ->
      typed = significant(exact, digits, :ceiling)
      {:ok, typed_q96} = BidActions.price_q96(typed, decimals)
      if div(typed_q96, spacing) * spacing == q96, do: typed
    end)
  end

  # Whole currency per whole token, with every digit a Q96 price carries, as
  # a coefficient and a power of ten.
  defp exact(q96, decimals),
    do: {q96 * Integer.pow(5, 96) * Integer.pow(10, 18), -(96 + decimals)}

  # Rounded to `digits` significant digits in whole-number arithmetic:
  # Decimal's own rounding would first cut a Q96 price to its context precision.
  defp significant({coef, exp}, digits, rounding) do
    cut = max(length(Integer.digits(coef)) - digits, 0)
    unit = Integer.pow(10, cut)
    kept = div(coef, unit)
    left = rem(coef, unit)

    kept =
      case rounding do
        :ceiling when left > 0 -> kept + 1
        :half_up when 2 * left >= unit and left > 0 -> kept + 1
        _rounding -> kept
      end

    kept |> trimmed(exp + cut) |> Decimal.to_string(:normal)
  end

  defp trimmed(coef, exp) when coef > 0 and rem(coef, 10) == 0,
    do: trimmed(div(coef, 10), exp + 1)

  defp trimmed(coef, exp), do: Decimal.new(1, coef, exp)

  defp logs(address, from_block, block, opts) do
    filter = %{
      address: address,
      fromBlock: "0x" <> Integer.to_string(from_block, 16),
      toBlock: "0x" <> Integer.to_string(block.number, 16),
      topics: [LabAbi.topic(@bid_submitted)]
    }

    case Rpc.request("eth_getLogs", [filter], opts) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _other} -> {:error, :invalid_chain_response}
      error -> error
    end
  end

  defp base_opts(%{kind: :agent}) do
    with {:ok, config} <- Lab.current(),
         do: {:ok, LabRpc.opts(config, "autolaunch auction book")}
  end

  defp base_opts(%{kind: :stocks}) do
    with {:ok, config} <- StocksLab.current(),
         do: {:ok, StocksLab.rpc_opts(config, "autolaunch auction book")}
  end
end
