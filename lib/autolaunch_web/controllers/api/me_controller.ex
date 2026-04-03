defmodule AutolaunchWeb.Api.MeController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
  alias Autolaunch.Portfolio
  alias AutolaunchWeb.ApiError

  def bids(conn, params) do
    case conn.assigns[:current_human] do
      nil ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      current_human ->
        filters =
          %{}
          |> maybe_put("status", Map.get(params, "status"))

        positions =
          current_human
          |> launch_module().list_positions(filters)
          |> maybe_filter_auction(Map.get(params, "auction"))

        json(conn, %{ok: true, items: positions})
    end
  end

  def profile(conn, _params) do
    case conn.assigns[:current_human] do
      nil ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      current_human ->
        case portfolio_module().get_snapshot(current_human) do
          {:ok, snapshot} ->
            json(conn, %{ok: true, profile: snapshot})

          {:error, _} ->
            ApiError.render(
              conn,
              :unprocessable_entity,
              "profile_unavailable",
              "Profile unavailable"
            )
        end
    end
  end

  def refresh_profile(conn, _params) do
    case conn.assigns[:current_human] do
      nil ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      current_human ->
        case portfolio_module().request_manual_refresh(current_human) do
          {:ok, snapshot} ->
            json(conn, %{ok: true, profile: snapshot})

          {:error, {:cooldown, seconds}} ->
            ApiError.render(
              conn,
              :too_many_requests,
              "profile_refresh_cooldown",
              "Profile refresh is cooling down for #{seconds} more seconds"
            )

          {:error, _} ->
            ApiError.render(
              conn,
              :unprocessable_entity,
              "profile_refresh_failed",
              "Profile refresh failed"
            )
        end
    end
  end

  def holdings(conn, _params) do
    case conn.assigns[:current_human] do
      nil ->
        ApiError.render(conn, :unauthorized, "auth_required", "Privy session required")

      current_human ->
        case portfolio_module().get_holdings(current_human) do
          {:ok, holdings} ->
            json(conn, %{ok: true, holdings: holdings})

          {:error, _} ->
            ApiError.render(
              conn,
              :unprocessable_entity,
              "holdings_unavailable",
              "Holdings unavailable"
            )
        end
    end
  end

  defp maybe_filter_auction(positions, nil), do: positions
  defp maybe_filter_auction(positions, ""), do: positions

  defp maybe_filter_auction(positions, auction_id),
    do: Enum.filter(positions, &(&1.auction_id == auction_id))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp launch_module do
    :autolaunch
    |> Application.get_env(:me_controller, [])
    |> Keyword.get(:launch_module, Launch)
  end

  defp portfolio_module do
    :autolaunch
    |> Application.get_env(:me_controller, [])
    |> Keyword.get(:portfolio_module, Portfolio)
  end
end
