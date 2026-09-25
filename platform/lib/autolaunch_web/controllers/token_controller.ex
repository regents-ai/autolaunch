defmodule AutolaunchWeb.TokenController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.Robinhood.Lab
  alias Autolaunch.TreasurySecurity
  alias AutolaunchWeb.MarketPage

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

      {:error, _error} ->
        internal_error(conn)
    end
  end

  defp public_token(token) do
    %{
      id: token.id,
      chain: if(Lab.chain?(token.auction.chain_id), do: "robinhood", else: "base"),
      chain_id: token.auction.chain_id,
      address: token.auction.token_address,
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

  defp loaded_report(%{treasury_security_report: %Ash.NotLoaded{}}), do: nil
  defp loaded_report(%{treasury_security_report: report}), do: report
  defp loaded_report(_token), do: nil

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
