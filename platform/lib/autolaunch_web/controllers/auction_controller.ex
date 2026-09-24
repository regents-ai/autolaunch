defmodule AutolaunchWeb.AuctionController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.Robinhood.{Auctions, Lab}
  alias Autolaunch.TreasurySecurity

  @modes ~w(all biddable live ended failed_minimum graduated)
  @sorts ~w(newest oldest)
  @query_parameters ~w(mode sort limit after)

  def index(conn, params) do
    autolaunch = conn.private[:auction_controller_autolaunch] || Autolaunch

    with {:ok, mode, sort, limit} <- list_options(params),
         {:ok, page} <-
           AutolaunchWeb.MarketPage.auctions(params["after"], mode, sort, limit, autolaunch) do
      json(conn, %{
        data:
          Enum.map(page.robinhood, &robinhood_auction/1) ++
            Enum.map(page.records, &public_auction/1),
        pagination: page.pagination,
        robinhood_unavailable: page.robinhood_unavailable
      })
    else
      {:error, :invalid_query} -> invalid_request(conn)
      {:error, _error} -> internal_error(conn)
    end
  end

  # A Base auction is named by its id; a Robinhood auction, which has none, by
  # its address, as on /robinhood/auctions/:auction.
  def show(conn, %{"id" => id} = params) do
    with true <- Map.keys(params) == ["id"],
         {:ok, entry} <- auction_entry(conn, id) do
      json(conn, %{data: entry})
    else
      false -> invalid_request(conn)
      :not_found -> not_found(conn)
      {:error, _error} -> internal_error(conn)
    end
  end

  defp auction_entry(conn, id) do
    case Ash.Type.UUID.cast_input(id, []) do
      {:ok, _id} -> base_auction_entry(conn, id)
      :error -> robinhood_auction_entry(id)
    end
  end

  defp base_auction_entry(conn, id) do
    case autolaunch(conn).get_public_auction(id, actor: nil) do
      {:ok, nil} -> :not_found
      {:ok, auction} -> {:ok, public_auction(auction)}
      {:error, error} -> {:error, error}
    end
  end

  defp robinhood_auction_entry(address) do
    case Auctions.fetch(address) do
      {:ok, auction} -> {:ok, robinhood_auction(auction)}
      {:error, :not_found} -> :not_found
      {:error, error} -> {:error, error}
    end
  end

  def bid_quote(conn, %{"id" => id} = params) do
    autolaunch = autolaunch(conn)

    with true <- Map.keys(params) |> Enum.sort() == ~w(amount id max_price),
         {:ok, quote} <-
           autolaunch.quote_auction_bid(id, params["amount"], params["max_price"]) do
      json(conn, %{data: quote})
    else
      false -> invalid_request(conn)
      {:error, :auction_not_found} -> not_found(conn)
      {:error, _reason} -> invalid_request(conn)
    end
  end

  defp list_options(params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in @query_parameters)),
         mode when mode in @modes <- Map.get(params, "mode", "all"),
         sort when sort in @sorts <- Map.get(params, "sort", "newest"),
         {:ok, limit} <- parse_limit(Map.get(params, "limit"), 50) do
      {:ok, mode, sort, limit}
    else
      _error -> {:error, :invalid_query}
    end
  end

  defp autolaunch(conn),
    do: conn.private[:auction_controller_autolaunch] || Autolaunch

  defp parse_limit(nil, maximum), do: {:ok, maximum}

  defp parse_limit(value, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> {:ok, limit |> max(1) |> min(maximum)}
      _error -> {:error, :invalid_query}
    end
  end

  defp parse_limit(_value, _maximum), do: {:error, :invalid_query}

  defp public_auction(auction) do
    %{
      id: auction.id,
      chain: "base",
      chain_id: auction.chain_id,
      address: auction.auction_address,
      title: auction.title,
      token_symbol: auction.token_symbol,
      summary: auction.summary,
      featured: auction.featured,
      kind: to_string(auction.kind),
      state: to_string(auction.state),
      minimum_reached: auction.minimum_reached,
      opened_at: iso8601(auction.opened_at),
      quote_token: %{
        address: auction.quote_token_address,
        symbol: auction.quote_token_symbol,
        decimals: auction.quote_token_decimals
      },
      clearing_price: auction.current_clearing_price,
      treasury_security: TreasurySecurity.public_view(loaded_report(auction))
    }
  end

  # The chain is the only record of a Robinhood auction, so the entry carries
  # what the chain answers: no id, summary, opening time or treasury report.
  defp robinhood_auction(auction) do
    %{
      chain: "robinhood",
      chain_id: Lab.chain_id(),
      address: auction.auction,
      launch_id: auction.launch_id,
      title: auction.name,
      token_symbol: auction.symbol,
      kind: "stocks",
      state: to_string(auction.state),
      minimum_reached: auction.minimum_reached,
      quote_token: %{
        address: auction.stock_address,
        symbol: auction.stock_symbol,
        decimals: auction.stock_decimals
      },
      clearing_price: auction.clearing_price,
      raised: auction.raised
    }
  end

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
