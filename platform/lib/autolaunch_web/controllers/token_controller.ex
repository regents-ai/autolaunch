defmodule AutolaunchWeb.TokenController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias Autolaunch.TreasurySecurity

  def index(conn, params) do
    autolaunch = conn.private[:token_controller_autolaunch] || Autolaunch

    with {:ok, limit} <- list_limit(params),
         {:ok, page_opts} <- AutolaunchWeb.PublicPage.options(params["after"], :tokens, limit),
         {:ok, page} <- autolaunch.page_public_tokens(actor: nil, page: page_opts) do
      json(conn, %{
        data: Enum.map(page.results, &public_token/1),
        pagination: AutolaunchWeb.PublicPage.metadata(page, :tokens)
      })
    else
      {:error, :invalid_query} -> invalid_request(conn)
      {:error, _error} -> internal_error(conn)
    end
  end

  defp list_limit(params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ~w(limit after))),
         {:ok, limit} <- parse_limit(Map.get(params, "limit")) do
      {:ok, limit}
    else
      _error -> {:error, :invalid_query}
    end
  end

  defp parse_limit(nil), do: {:ok, 100}

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> {:ok, limit |> max(1) |> min(100)}
      _error -> {:error, :invalid_query}
    end
  end

  defp parse_limit(_value), do: {:error, :invalid_query}

  defp public_token(token) do
    %{
      id: token.id,
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
