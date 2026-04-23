defmodule AutolaunchWeb.Api.BidController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias AutolaunchWeb.ApiErrorTranslator
  alias AutolaunchWeb.LiveUpdates

  def exit(conn, %{"id" => id} = params) do
    case launch_module().exit_bid(id, params, conn.assigns[:current_human]) do
      {:ok, position} ->
        LiveUpdates.broadcast([:market, :positions])
        json(conn, %{ok: true, bid: position})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :bid_exit, reason)
    end
  end

  def return_usdc(conn, %{"id" => id} = params) do
    case launch_module().return_bid(id, params, conn.assigns[:current_human]) do
      {:ok, position} ->
        LiveUpdates.broadcast([:market, :positions])
        json(conn, %{ok: true, bid: position})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :bid_return, reason)
    end
  end

  def claim(conn, %{"id" => id} = params) do
    case launch_module().claim_bid(id, params, conn.assigns[:current_human]) do
      {:ok, position} ->
        LiveUpdates.broadcast([:market, :positions])
        json(conn, %{ok: true, bid: position})

      {:error, reason} ->
        ApiErrorTranslator.render(conn, :bid_claim, reason)
    end
  end

  defp launch_module do
    :autolaunch
    |> Application.get_env(:bid_controller, [])
    |> Keyword.get(:launch_module, Launch)
  end
end
