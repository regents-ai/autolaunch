defmodule AutolaunchWeb.MarketAnswer do
  @moduledoc """
  The public market reads: the auction and token lists, one auction, one
  token, a treasury report and a bid estimate. Each answer is the whole JSON
  document its route sends (`AutolaunchWeb.AuctionController`,
  `AutolaunchWeb.TokenController`, `AutolaunchWeb.TreasuryController`) and its
  hosted MCP tool gives as its result, or the refusal both give
  (`AutolaunchWeb.Refusal`). Each takes the route's parameters as the route
  receives them: by name, as text (`params/1` turns a hosted tool's input into
  them).
  """

  alias Autolaunch.AuctionFigures
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.TreasurySecurity
  alias AutolaunchWeb.{MarketPage, Paths, ReadFailure, Refusal, UsdValue}
  alias AutolaunchWeb.Components.BidPlaced
  alias RegentChain.Address

  @cache :autolaunch_public_auctions

  @doc "The cache that keeps each public auction list for a few seconds (`Autolaunch.Application`)."
  def cache, do: @cache

  @doc "A hosted tool's input as its route's parameters: each value given, as text, by its name."
  def params(arguments),
    do: Map.new(arguments, fn {name, value} -> {Atom.to_string(name), to_string(value)} end)

  @doc """
  A page of the auction list. The same list asked for again within a few
  seconds is answered from the cache; a refused or failed read is never kept.
  """
  def auctions(params) do
    case Cachex.fetch(@cache, params, &auction_page/1) do
      {kept, body} when kept in [:ok, :commit] -> {:ok, body}
      {:ignore, {:error, :invalid_query}} -> invalid_query()
      {:ignore, {:error, error}} -> failed("public auctions read", error)
    end
  end

  defp auction_page(params) do
    case MarketPage.read(params, "auctions") do
      {:ok, page} ->
        {:commit,
         %{
           data: Enum.map(page.records, &public_auction(&1, page.robinhood_unavailable)),
           pagination: page.pagination,
           robinhood_unavailable: page.robinhood_unavailable
         }}

      error ->
        {:ignore, error}
    end
  end

  @doc "One listed auction, named by its id; a Robinhood auction also by its contract address."
  def auction(%{"id" => id} = params) when map_size(params) == 1 do
    robinhood_unavailable = Autolaunch.ChainHead.stale?("robinhood")

    case auction_entry(id) do
      {:ok, auction} ->
        {:ok,
         %{
           data: public_auction(auction, robinhood_unavailable),
           robinhood_unavailable: robinhood_unavailable
         }}

      :not_found ->
        auction_not_found()

      {:error, error} ->
        failed("public auction read", error)
    end
  end

  def auction(_params), do: invalid_query()

  defp auction_entry(id) do
    case Ash.Type.UUID.cast_input(id, []) do
      {:ok, _id} -> entry(Autolaunch.get_listed_auction(id, actor: nil))
      :error -> robinhood_entry(Address.normalize(id))
    end
  end

  defp robinhood_entry({:ok, address}),
    do: entry(Autolaunch.get_robinhood_auction(address, actor: nil))

  defp robinhood_entry(:error), do: :not_found

  defp entry({:ok, nil}), do: :not_found
  defp entry({:ok, auction}), do: {:ok, auction}
  defp entry({:error, error}), do: {:error, error}

  @doc "A bid's estimate from the auction's stored public figures."
  def bid_quote(%{"id" => id, "amount" => amount, "max_price" => max_price} = params)
      when map_size(params) == 3 do
    case Autolaunch.quote_auction_bid(id, amount, max_price) do
      {:ok, quote} ->
        {:ok, %{data: quote}}

      {:error, :auction_not_found} ->
        auction_not_found()

      {:error, :estimate_not_offered} ->
        {:error,
         Refusal.new(
           :unprocessable_entity,
           "estimate_not_offered",
           "Bid estimates cover Base auctions only. This auction is on Robinhood."
         )}

      {:error, :invalid_amount} ->
        invalid_decimal("invalid_amount", "amount")

      {:error, :invalid_max_price} ->
        invalid_decimal("invalid_max_price", "max_price")

      {:error, reason} when reason in [:database_unavailable, :price_unreadable] ->
        failed("bid quote read", reason)
    end
  end

  def bid_quote(_params), do: invalid_query()

  @doc "A page of the token list."
  def tokens(params) do
    case MarketPage.read(params, "tokens") do
      {:ok, page} ->
        rates = UsdValue.rates()

        {:ok,
         %{
           data: Enum.map(page.records, &public_token(&1, rates)),
           pagination: page.pagination,
           robinhood_unavailable: page.robinhood_unavailable
         }}

      {:error, :invalid_query} ->
        invalid_query()

      {:error, error} ->
        failed("public tokens read", error)
    end
  end

  @doc "One listed token, named by its id, with its revenue history."
  def token(%{"id" => id} = params) when map_size(params) == 1 do
    case Ash.Type.UUID.cast_input(id, []) do
      {:ok, uuid} when is_binary(uuid) -> listed_token(uuid)
      _invalid -> invalid_query()
    end
  end

  def token(_params), do: invalid_query()

  defp listed_token(uuid) do
    case read_token(uuid) do
      {:ok, nil} ->
        {:error, Refusal.new(:not_found, "not_found", "That token is not publicly listed.")}

      {:ok, {token, history}} ->
        {:ok, %{data: token_detail(token, UsdValue.rates(), history)}}

      {:error, error} ->
        failed("public token read", error)
    end
  end

  @doc "The current treasury-security report for a treasury address."
  def treasury(%{"address" => address} = params) when map_size(params) == 1 do
    case Autolaunch.current_treasury_security(address, actor: nil) do
      {:ok, nil} ->
        {:error, Refusal.new(:not_found, "not_found", "Treasury report not found.")}

      {:ok, report} ->
        {:ok, %{data: TreasurySecurity.public_view(report)}}

      :error ->
        invalid_treasury()

      {:error, error} ->
        failed("treasury report read", error)
    end
  end

  def treasury(_params), do: invalid_treasury()

  @doc "The refusal for parameters a market read does not take."
  def invalid_query,
    do:
      {:error, Refusal.new(:bad_request, "invalid_request", "The query parameters are invalid.")}

  @doc "The refusal for a treasury address the report read does not take."
  def invalid_treasury,
    do: {:error, Refusal.new(:bad_request, "invalid_request", "The treasury address is invalid.")}

  defp invalid_decimal(code, field),
    do:
      {:error,
       Refusal.new(
         :unprocessable_entity,
         code,
         "#{field} must be a plain decimal string greater than zero, such as \"12.5\"."
       )}

  defp auction_not_found,
    do: {:error, Refusal.new(:not_found, "not_found", "Auction not found.")}

  # A read that failed is logged by its kind and module only, then answered
  # with the generic error (`AutolaunchWeb.ReadFailure`).
  defp failed(what, error) do
    ReadFailure.log(what, error)

    {:error,
     Refusal.new(:internal_server_error, "internal_error", "The request could not be completed.")}
  end

  # Every figure an agent decides with, from the stored record. A figure the
  # record does not hold yet is null, and `unavailable` names why.
  defp public_auction(auction, robinhood_unavailable) do
    robinhood? = Lab.chain?(auction.chain_id)

    %{
      id: auction.id,
      chain: if(robinhood?, do: "robinhood", else: "base"),
      chain_id: auction.chain_id,
      address: auction.auction_address,
      url: Paths.auction_url(auction),
      title: auction.title,
      token_symbol: auction.token_symbol,
      summary: auction.summary,
      featured: auction.featured,
      kind: launch_type(auction.kind),
      state: to_string(auction.state),
      opened_at: iso8601(auction.opened_at),
      estimated_end_at: iso8601(auction.estimated_end_at),
      quote_token: %{
        address: auction.quote_token_address,
        symbol: auction.quote_token_symbol,
        decimals: auction.quote_token_decimals
      },
      clearing_price: AuctionFigures.stated(auction.current_clearing_price),
      token_allocation: decimal(AuctionFigures.token_allocation(auction)),
      bid_volume: decimal(auction.bid_volume),
      bid_volume_usd: decimal(auction.bid_volume_usd),
      minimum_raise: decimal(AuctionFigures.minimum(auction)),
      currency_raised: decimal(auction.currency_raised),
      percent_met: AuctionFigures.percent_met(auction),
      minimum_reached: auction.minimum_reached,
      record_updated_at: iso8601(auction.updated_at),
      unavailable: unavailable(auction, robinhood? and robinhood_unavailable),
      treasury_security: TreasurySecurity.public_view(loaded_report(auction))
    }
  end

  # The launch type by its public name; the stored kind keeps its original name.
  defp launch_type(:agent), do: "revstake"
  defp launch_type(:stocks), do: "memestock"

  # Why each missing figure is missing. The site's chain readers record the
  # bid history (volume and end time) and the amount raised; until they have,
  # a figure is `not_recorded_yet`. Robinhood's reader also says when its last
  # read of the chain failed, so an amount it never recorded is then
  # `chain_unreadable`. A volume recorded while the quote token had no known
  # dollar price has no dollar figure.
  defp unavailable(auction, robinhood_unreadable?) do
    raised = if robinhood_unreadable?, do: "chain_unreadable", else: "not_recorded_yet"

    [
      estimated_end_at: {auction.estimated_end_at, "not_recorded_yet"},
      bid_volume: {auction.bid_volume, "not_recorded_yet"},
      bid_volume_usd:
        {auction.bid_volume_usd,
         if(auction.bid_volume, do: "no_usd_price", else: "not_recorded_yet")},
      currency_raised: {auction.currency_raised, raised},
      percent_met: {auction.currency_raised, raised}
    ]
    |> Enum.filter(fn {_figure, {value, _reason}} -> is_nil(value) end)
    |> Map.new(fn {figure, {_value, reason}} -> {figure, reason} end)
  end

  # The price, market cap and bid volume the lists show beside the token, in
  # its currency and in dollars. A dollar figure is null while its currency
  # has no dollar price, as on a test network.
  defp public_token(token, rates) do
    rate = UsdValue.auction_rate(rates, token.auction)

    %{
      id: token.id,
      chain: if(Lab.chain?(token.auction.chain_id), do: "robinhood", else: "base"),
      chain_id: token.auction.chain_id,
      address: token.auction.token_address,
      url: Paths.token_url(token.auction),
      auction_id: token.auction_id,
      subject_id: token.subject_id,
      name: token.name,
      symbol: token.symbol,
      summary: token.summary,
      graduated_at: DateTime.to_iso8601(token.graduated_at),
      top_rank: token.top_rank,
      quote_token: %{
        address: token.auction.quote_token_address,
        symbol: token.auction.quote_token_symbol,
        decimals: token.auction.quote_token_decimals
      },
      price_quote: AuctionFigures.stated(token.price_quote),
      price_usd: usd(token.price_quote, rate),
      price_updated_at: token.price_updated_at,
      market_cap: AuctionFigures.stated(token.market_cap),
      market_cap_usd: usd(token.market_cap, rate),
      bid_volume: decimal(token.auction.bid_volume),
      bid_volume_usd: decimal(token.auction.bid_volume_usd),
      treasury_security: TreasurySecurity.public_view(loaded_report(token))
    }
  end

  defp usd(nil, _rate), do: nil
  defp usd(_amount, nil), do: nil

  defp usd(price, rate) when is_binary(price),
    do: usd(Decimal.new(price, max_digits: :infinity), rate)

  defp usd(amount, rate), do: AuctionFigures.stated(Decimal.mult(amount, rate))

  # The listed token with its revenue history; nil when it is not listed.
  defp read_token(uuid) do
    with {:ok, %{} = token} <- Autolaunch.get_listed_token(uuid, actor: nil, load: [:market_cap]),
         {:ok, history} <- revenue_history(token) do
      {:ok, {token, history}}
    end
  end

  defp token_detail(token, rates, history) do
    Map.merge(public_token(token, rates), %{
      auction_url: Paths.auction_url(token.auction),
      token_supply: decimal(token.auction.token_supply),
      revenue_history: history
    })
  end

  # What a Revstake token's splitter has recognized, newest first, as the
  # site recorded it from the splitter's logs; null for a Memestock token,
  # which has no revenue splitter.
  defp revenue_history(%{auction: %{kind: :agent}} = token) do
    with {:ok, rows} <- Autolaunch.token_revenue(token.id, actor: nil) do
      {:ok,
       Enum.map(rows, fn row ->
         %{
           amount: decimal(row.amount),
           asset: row.asset_symbol,
           staker_share: decimal(row.staker_share),
           recorded_at: DateTime.to_iso8601(row.occurred_at),
           transaction_hash: row.transaction_hash,
           transaction_url: BidPlaced.transaction_url(:base, row.transaction_hash)
         }
       end)}
    end
  end

  defp revenue_history(_memestock), do: {:ok, nil}

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)

  defp loaded_report(%{treasury_security_report: %Ash.NotLoaded{}}), do: nil
  defp loaded_report(%{treasury_security_report: report}), do: report
  defp loaded_report(_record), do: nil
end
