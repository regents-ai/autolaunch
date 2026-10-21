defmodule AutolaunchWeb.TokenController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.AuctionFigures
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.TreasurySecurity
  alias AutolaunchWeb.{ApiError, MarketPage, Paths, ReadFailure, UsdValue}
  alias AutolaunchWeb.Components.BidPlaced

  def index(conn, params) do
    case MarketPage.read(params, "tokens") do
      {:ok, page} ->
        rates = UsdValue.rates()

        json(conn, %{
          data: Enum.map(page.records, &public_token(&1, rates)),
          pagination: page.pagination,
          robinhood_unavailable: page.robinhood_unavailable
        })

      {:error, :invalid_query} ->
        invalid_request(conn)

      {:error, error} ->
        internal_error(conn, "public tokens read", error)
    end
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

  def show(conn, %{"id" => id} = params) do
    conn = Plug.Conn.fetch_query_params(conn)

    with true <- conn.query_params == %{} and Map.keys(params) == ["id"],
         {:ok, uuid} <- Ash.Type.UUID.cast_input(id, []) do
      case read_token(uuid) do
        {:ok, nil} ->
          ApiError.send(conn, :not_found, "not_found", "That token is not publicly listed.")

        {:ok, {token, history}} ->
          json(conn, %{data: token_detail(token, UsdValue.rates(), history)})

        {:error, error} ->
          internal_error(conn, "public token read", error)
      end
    else
      _invalid -> invalid_request(conn)
    end
  end

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

  defp loaded_report(%{treasury_security_report: %Ash.NotLoaded{}}), do: nil
  defp loaded_report(%{treasury_security_report: report}), do: report
  defp loaded_report(_token), do: nil

  defp invalid_request(conn),
    do: ApiError.send(conn, :bad_request, "invalid_request", "The query parameters are invalid.")

  # A read that failed is logged by its kind and module only, then answered
  # with the generic error (`AutolaunchWeb.ReadFailure`).
  defp internal_error(conn, what, error) do
    ReadFailure.log(what, error)

    ApiError.send(
      conn,
      :internal_server_error,
      "internal_error",
      "The request could not be completed."
    )
  end
end
