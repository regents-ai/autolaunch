defmodule AutolaunchWeb.Api.AuctionController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiError

  def index(conn, params) do
    current_human = conn.assigns[:current_human]

    filters = %{
      "sort" => Map.get(params, "sort", "hottest"),
      "status" => Map.get(params, "status", ""),
      "chain" => Map.get(params, "chain", ""),
      "mine_only" => Map.get(params, "mine_only", false)
    }

    json(conn, %{
      ok: true,
      items: launch_module().list_auctions(filters, current_human),
      generated_at: DateTime.utc_now()
    })
  end

  def show(conn, %{"id" => id}) do
    case launch_module().get_auction(id, conn.assigns[:current_human]) do
      nil -> ApiError.render(conn, :not_found, "auction_not_found", "Auction not found")
      auction -> json(conn, %{ok: true, auction: auction})
    end
  end

  def bid_quote(conn, %{"id" => id} = params) do
    case launch_module().quote_bid(id, params, conn.assigns[:current_human]) do
      {:ok, quote} ->
        json(conn, Map.put(quote, :ok, true))

      {:error, :auction_not_found} ->
        ApiError.render(conn, :not_found, "auction_not_found", "Auction not found")

      {:error, :bid_must_be_above_clearing_price} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "bid_above_clearing_required",
          "Bid max price must be above the current clearing price"
        )

      {:error, :invalid_tick_price} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_tick_price",
          "Bid max price must land on a valid auction tick"
        )

      {:error, :auction_is_over} ->
        ApiError.render(conn, :unprocessable_entity, "auction_is_over", "Auction is over")

      {:error, :auction_not_started} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "auction_not_started",
          "Auction has not started"
        )

      {:error, :auction_sold_out} ->
        ApiError.render(conn, :unprocessable_entity, "auction_sold_out", "Auction has sold out")

      {:error, reason} ->
        ApiError.render(conn, :unprocessable_entity, "bid_quote_invalid", inspect(reason))
    end
  end

  def create_bid(conn, %{"id" => id} = params) do
    case launch_module().place_bid(id, params, conn.assigns[:current_human]) do
      {:ok, bid} ->
        json(conn, %{ok: true, bid: bid})

      {:error, :unauthorized} ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      {:error, :auction_not_found} ->
        ApiError.render(conn, :not_found, "auction_not_found", "Auction not found")

      {:error, :transaction_pending} ->
        ApiError.render(
          conn,
          :accepted,
          "transaction_pending",
          "Transaction is still pending confirmation"
        )

      {:error, :transaction_failed} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "transaction_failed",
          "Transaction failed onchain"
        )

      {:error, reason} ->
        ApiError.render(conn, :unprocessable_entity, "bid_invalid", inspect(reason))
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:auction_controller, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
