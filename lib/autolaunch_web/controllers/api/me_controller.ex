defmodule AutolaunchWeb.Api.MeController do
  use AutolaunchWeb, :controller

  alias Autolaunch.Launch
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
end
