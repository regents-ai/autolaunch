defmodule AutolaunchWeb.MarketPage do
  @moduledoc """
  One page of a public market list for the JSON API, read through the
  website's own discovery (`Autolaunch.HomeMarket`) with the same option names
  and meanings. A parameter or value the list does not know is refused.

  `robinhood_unavailable` says Robinhood could not be read just now, so its
  entries show what was last read from it.
  """

  alias Autolaunch.{HomeMarket, Search}
  alias AutolaunchWeb.LabMarket

  @filters ~w(q chain kind x ens github limit after)
  @parameters %{"auctions" => ~w(state sort) ++ @filters, "tokens" => @filters}
  @limits %{"auctions" => 50, "tokens" => 100}

  @doc "The page `params` asks for from the auctions or tokens list, as `view` names it."
  def read(params, view) do
    with {:ok, options, limit} <- options(params, view),
         {:ok, page} <- HomeMarket.read(options, params["after"], limit) do
      {:ok,
       %{
         records: page.records,
         robinhood_unavailable: LabMarket.robinhood_stale?(),
         pagination: %{has_more: page.has_more, next_cursor: page.next_cursor}
       }}
    else
      {:error, %Ash.Error.Invalid{}} -> {:error, :invalid_query}
      error -> error
    end
  end

  # State, sort, chain and kind values are checked by the list's own read.
  defp options(params, view) do
    with true <- Enum.all?(params, &known?(&1, @parameters[view])),
         {:ok, x} <- flag(params["x"]),
         {:ok, ens} <- flag(params["ens"]),
         {:ok, github} <- flag(params["github"]),
         {:ok, limit} <- limit(params["limit"], @limits[view]) do
      {:ok,
       %{
         view: view,
         q: Search.normalize(params["q"]),
         state: Map.get(params, "state", "all"),
         sort: Map.get(params, "sort", "newest"),
         chain: Map.get(params, "chain", "all"),
         kind: Map.get(params, "kind", "all"),
         x: x,
         ens: ens,
         github: github
       }, limit}
    else
      _invalid -> {:error, :invalid_query}
    end
  end

  defp known?({key, value}, parameters), do: key in parameters and is_binary(value)

  defp flag(nil), do: {:ok, false}
  defp flag("true"), do: {:ok, true}
  defp flag("false"), do: {:ok, false}
  defp flag(_value), do: :error

  defp limit(nil, maximum), do: {:ok, maximum}

  defp limit(value, maximum) do
    case Integer.parse(value) do
      {limit, ""} -> {:ok, limit |> max(1) |> min(maximum)}
      _invalid -> :error
    end
  end
end
