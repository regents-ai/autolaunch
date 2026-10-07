defmodule Autolaunch.AuctionBook do
  @moduledoc """
  What a bidder needs to see in an open auction, read from the auction
  contract each time a page asks: the price everyone pays right now and the
  lowest maximum a new bid can use to get tokens.

  The price is the one the auction would record in this block, from a call to
  `checkpoint()` that is never sent, so it counts bids the auction has not
  recorded a price for yet. A new bid's maximum has to sit on the auction's
  price grid and above that price, so the lowest one that gets tokens is the
  next grid step above it.

  A bid whose maximum is above the price buys at the price every block; a bid
  exactly at it shares what the higher bids leave; a bid below it has stopped
  buying.
  """

  alias Autolaunch.{BidActions, BidPrice}
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.Lab
  alias Autolaunch.LabAbi
  alias Autolaunch.LabRpc
  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Lab, as: StocksLab

  @type standing :: :in | :sharing | :outbid

  @doc "A Base auction's book, read at the latest block."
  @spec base(map()) :: {:ok, map()} | {:error, atom()}
  def base(%{auction_address: address, quote_token_decimals: decimals} = auction)
      when is_binary(address) do
    with {:ok, opts} <- base_opts(auction),
         {:ok, block} <- Rpc.latest_block(opts),
         do: read(address, decimals, block, opts)
  end

  def base(_auction), do: {:error, :no_auction_contract}

  @doc """
  A Robinhood auction's book, read at the latest block by its address alone:
  the auction names its currency, and the currency its decimals.
  """
  @spec robinhood(String.t()) :: {:ok, map()} | {:error, atom()}
  def robinhood(address) when is_binary(address) do
    with {:ok, config} <- RobinhoodLab.current(),
         opts = RobinhoodLab.rpc_opts(config),
         {:ok, block} <- Rpc.latest_block(opts),
         {:ok, currency} <- Rpc.call_uint(address, LabAbi.selector("currency()"), block, opts),
         {:ok, currency} <- Abi.word_address(currency),
         {:ok, decimals} <- Rpc.call_uint(currency, LabAbi.selector("decimals()"), block, opts) do
      read(address, decimals, block, opts)
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

  @doc "Where a stored Base bid stands against its auction's book, from its maximum price."
  @spec bid_standing(map(), map(), map()) :: standing()
  def bid_standing(%{max_price: max_price}, %{quote_token_decimals: decimals}, book) do
    {:ok, price_q96} = BidActions.price_q96(max_price, decimals)
    standing(price_q96, book)
  end

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

    if String.match?(amount, ~r/\A(?:\d+(?:\.\d+)?|\.\d+)\z/) and Decimal.gt?(plain(amount), 0),
      do:
        amount
        |> plain()
        |> Decimal.div(price)
        |> Decimal.normalize()
        |> Decimal.to_string(:normal)
  end

  defp plain(typed), do: Decimal.new(String.trim(typed), max_digits: :infinity)

  @doc """
  The book of the auction at `address`, read at `block`: the reading `base/1`
  and `robinhood/1` return, for a caller that reads more of the same auction
  at the same block.
  """
  def read(address, decimals, block, opts) do
    with {:ok, spacing} <- uint(address, "tickSpacing()", block, opts),
         {:ok, cap} <- uint(address, "MAX_BID_PRICE()", block, opts),
         {:ok, [clearing | _checkpoint]} <-
           Rpc.call_words(address, LabAbi.selector("checkpoint()"), block, 6, opts) do
      to_beat = (div(clearing, spacing) + 1) * spacing

      {:ok,
       %{
         block: block,
         clearing_q96: clearing,
         clearing: BidPrice.decimal(clearing, decimals),
         decimals: decimals,
         tick_spacing_q96: spacing,
         max_bid_price_q96: cap,
         price_to_beat_q96: if(to_beat <= cap, do: to_beat),
         price_to_beat: if(to_beat <= cap, do: entered(to_beat, spacing, decimals))
       }}
    end
  end

  defp uint(address, signature, block, opts),
    do: Rpc.call_uint(address, LabAbi.selector(signature), block, opts)

  @doc """
  A grid price as the shortest decimal a bidder can type that the bid form
  turns back into exactly that grid price.
  """
  @spec typed(pos_integer(), map()) :: String.t()
  def typed(q96, %{tick_spacing_q96: spacing, decimals: decimals}),
    do: entered(q96, spacing, decimals)

  # The shortest price a bidder can type that the bid form turns back into
  # exactly this grid price: rounded up, so it never falls to the grid step
  # below, with as few digits as keep it under the step above.
  defp entered(q96, spacing, decimals) do
    exact = exact(q96, decimals)

    Enum.find_value(Stream.iterate(1, &(&1 + 1)), fn digits ->
      typed = rounded_up(exact, digits)
      {:ok, typed_q96} = BidActions.price_q96(typed, decimals)
      if div(typed_q96, spacing) * spacing == q96, do: typed
    end)
  end

  # Whole currency per whole token, with every digit a Q96 price carries, as
  # a coefficient and a power of ten.
  defp exact(q96, decimals),
    do: {q96 * Integer.pow(5, 96) * Integer.pow(10, 18), -(96 + decimals)}

  # Rounded up to `digits` significant digits in whole-number arithmetic:
  # Decimal's own rounding would first cut a Q96 price to its context precision.
  defp rounded_up({coef, exp}, digits) do
    cut = max(length(Integer.digits(coef)) - digits, 0)
    unit = Integer.pow(10, cut)
    kept = if rem(coef, unit) > 0, do: div(coef, unit) + 1, else: div(coef, unit)
    kept |> trimmed(exp + cut) |> Decimal.to_string(:normal)
  end

  defp trimmed(coef, exp) when coef > 0 and rem(coef, 10) == 0,
    do: trimmed(div(coef, 10), exp + 1)

  defp trimmed(coef, exp), do: Decimal.new(1, coef, exp)

  @doc "The read options for a Base auction's chain, by the launch kind that says which deployment it is on."
  def base_opts(%{kind: :agent}) do
    with {:ok, config} <- Lab.current(),
         do: {:ok, LabRpc.opts(config, "autolaunch auction book")}
  end

  def base_opts(%{kind: :stocks}) do
    with {:ok, config} <- StocksLab.current(),
         do: {:ok, StocksLab.rpc_opts(config, "autolaunch auction book")}
  end
end
