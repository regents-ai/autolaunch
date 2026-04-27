defmodule AutolaunchWeb.Api.AuctionController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiErrorTranslator

  import AutolaunchWeb.Api.ControllerHelpers

  def index(conn, params) do
    current_human = conn.assigns[:current_human]

    filters = %{
      "mode" => Map.get(params, "mode", "biddable"),
      "sort" => Map.get(params, "sort", "newest")
    }

    json(conn, %{
      ok: true,
      items: launch_module().list_auctions(filters, current_human),
      generated_at: DateTime.utc_now()
    })
  end

  def show(conn, %{"id" => id}) do
    case launch_module().get_auction(id, conn.assigns[:current_human]) do
      nil -> ApiErrorTranslator.render(conn, :auction_show, :auction_not_found)
      auction -> json(conn, %{ok: true, auction: auction})
    end
  end

  def returns(conn, params) do
    payload =
      launch_module().list_auction_returns(
        %{
          "limit" => Map.get(params, "limit"),
          "offset" => Map.get(params, "offset")
        },
        conn.assigns[:current_human]
      )

    json(conn, Map.put(payload, :ok, true))
  end

  def bid_quote(conn, %{"id" => id} = params) do
    case launch_module().quote_bid(id, params, conn.assigns[:current_human]) do
      {:ok, quote} ->
        json(conn, Map.put(quote, :ok, true))

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :auction_bid_quote, reason)
    end
  end

  def create_bid(conn, %{"id" => id} = params) do
    case launch_module().place_bid(id, params, conn.assigns[:current_human]) do
      {:ok, bid} ->
        json(conn, %{ok: true, bid: bid})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :auction_create_bid, reason)
    end
  end

  defp launch_module do
    configured_module(:auction_controller, :launch_module, Launch)
  end
end
