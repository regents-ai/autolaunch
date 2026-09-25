defmodule AutolaunchWeb.AuctionController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.AuctionFigures
  alias Autolaunch.Chain.Address
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.TreasurySecurity
  alias AutolaunchWeb.Components.MarketCard
  alias AutolaunchWeb.{Endpoint, LabMarket, MarketPage}

  def index(conn, params) do
    case MarketPage.read(params, "auctions") do
      {:ok, page} ->
        json(conn, %{
          data: Enum.map(page.records, &public_auction(&1, page.robinhood_unavailable)),
          pagination: page.pagination,
          robinhood_unavailable: page.robinhood_unavailable
        })

      {:error, :invalid_query} ->
        invalid_request(conn)

      {:error, _error} ->
        internal_error(conn)
    end
  end

  # Any listed auction is named by its id; a Robinhood auction also by its
  # address, as on /robinhood/auctions/:auction.
  def show(conn, %{"id" => id} = params) do
    robinhood_unavailable = LabMarket.robinhood_stale?()

    with true <- Map.keys(params) == ["id"],
         {:ok, auction} <- auction_entry(id) do
      json(conn, %{
        data: public_auction(auction, robinhood_unavailable),
        robinhood_unavailable: robinhood_unavailable
      })
    else
      false -> invalid_request(conn)
      :not_found -> not_found(conn)
      {:error, _error} -> internal_error(conn)
    end
  end

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

  def bid_quote(conn, %{"id" => id} = params) do
    with true <- Map.keys(params) |> Enum.sort() == ~w(amount id max_price),
         {:ok, quote} <- Autolaunch.quote_auction_bid(id, params["amount"], params["max_price"]) do
      json(conn, %{data: quote})
    else
      false -> invalid_request(conn)
      {:error, :auction_not_found} -> not_found(conn)
      {:error, _reason} -> invalid_request(conn)
    end
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
      url: Endpoint.url() <> MarketCard.auction_path(auction),
      title: auction.title,
      token_symbol: auction.token_symbol,
      summary: auction.summary,
      featured: auction.featured,
      kind: to_string(auction.kind),
      state: to_string(auction.state),
      opened_at: iso8601(auction.opened_at),
      estimated_end_at: iso8601(auction.estimated_end_at),
      quote_token: %{
        address: auction.quote_token_address,
        symbol: auction.quote_token_symbol,
        decimals: auction.quote_token_decimals
      },
      clearing_price: auction.current_clearing_price,
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

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)

  defp loaded_report(%{treasury_security_report: %Ash.NotLoaded{}}), do: nil
  defp loaded_report(%{treasury_security_report: report}), do: report
  defp loaded_report(_auction), do: nil

  defp invalid_request(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{
        code: "invalid_request",
        message: "The query parameters are invalid."
      }
    })
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{
        code: "not_found",
        message: "Auction not found."
      }
    })
  end

  defp internal_error(conn) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: %{
        code: "internal_error",
        message: "The request could not be completed."
      }
    })
  end
end
