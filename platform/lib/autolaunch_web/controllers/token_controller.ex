defmodule AutolaunchWeb.TokenController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.TreasurySecurity
  alias AutolaunchWeb.{ApiError, MarketPage, Paths, ReadFailure}

  def index(conn, params) do
    case MarketPage.read(params, "tokens") do
      {:ok, page} ->
        json(conn, %{
          data: Enum.map(page.records, &public_token/1),
          pagination: page.pagination,
          robinhood_unavailable: page.robinhood_unavailable
        })

      {:error, :invalid_query} ->
        invalid_request(conn)

      {:error, error} ->
        internal_error(conn, "public tokens read", error)
    end
  end

  defp public_token(token) do
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
      treasury_security: TreasurySecurity.public_view(loaded_report(token))
    }
  end

  def show(conn, %{"id" => id} = params) do
    conn = Plug.Conn.fetch_query_params(conn)

    with true <- conn.query_params == %{} and Map.keys(params) == ["id"],
         {:ok, uuid} <- Ash.Type.UUID.cast_input(id, []) do
      case Autolaunch.get_listed_token(uuid, actor: nil) do
        {:ok, nil} ->
          ApiError.send(conn, :not_found, "not_found", "That token is not publicly listed.")

        {:ok, token} ->
          json(conn, %{data: token_detail(token)})

        {:error, error} ->
          internal_error(conn, "public token read", error)
      end
    else
      _invalid -> invalid_request(conn)
    end
  end

  defp token_detail(token) do
    Map.merge(public_token(token), %{
      auction_url: Paths.auction_url(token.auction),
      price_quote: token.price_quote,
      price_updated_at: token.price_updated_at,
      quote_token: %{
        address: token.auction.quote_token_address,
        symbol: token.auction.quote_token_symbol,
        decimals: token.auction.quote_token_decimals
      },
      token_supply: decimal(token.auction.token_supply)
    })
  end

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
