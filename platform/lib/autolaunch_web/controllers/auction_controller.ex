defmodule AutolaunchWeb.AuctionController do
  use AutolaunchWeb, :controller

  alias Autolaunch
  alias AutolaunchWeb.{ApiError, MarketAnswer, ReadFailure}

  # Each answer is the one its hosted MCP tool gives too (`AutolaunchWeb.MarketAnswer`).
  def index(conn, params), do: ApiError.answer(conn, MarketAnswer.auctions(params))

  # Any listed auction is named by its id; a Robinhood auction also by its
  # contract address.
  def show(conn, params), do: ApiError.answer(conn, MarketAnswer.auction(params))

  @doc """
  Live and graduated auction counts for each launch type and chain, from the
  action the hosted MCP tool runs too (`Autolaunch.Auction`, `:counts`).
  """
  def counts(conn, params) do
    with true <- params == %{},
         {:ok, counts} <- Autolaunch.auction_counts(actor: nil) do
      json(conn, %{data: counts})
    else
      false -> ApiError.answer(conn, MarketAnswer.invalid_query())
      {:error, error} -> internal_error(conn, "public auction counts read", error)
    end
  end

  def bid_quote(conn, params), do: ApiError.answer(conn, MarketAnswer.bid_quote(params))

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
