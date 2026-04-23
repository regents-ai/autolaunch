defmodule Autolaunch.Launch.Directory do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Autolaunch.Launch.Auction
  alias Autolaunch.Launch.Core
  alias Autolaunch.Repo

  def list_auctions(filters \\ %{}, current_human \\ nil) do
    with {:ok, active_chain_id} <- Core.launch_chain_id() do
      auctions =
        Repo.all(
          from auction in Auction,
            where: auction.chain_id == ^active_chain_id,
            order_by: [desc: auction.inserted_at]
        )

      identity_index = Core.identity_index_for_auctions(auctions)
      job_index = Core.job_index_for_auctions(auctions)
      human_launch_counts = Core.world_launch_counts()
      x_accounts = Core.x_accounts_for_auctions(auctions)

      auctions
      |> Enum.map(
        &Core.serialize_auction(
          &1,
          current_human,
          identity_index,
          job_index,
          human_launch_counts,
          x_accounts
        )
      )
      |> filter_auctions(filters)
      |> sort_auctions(filters)
    else
      _ -> []
    end
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
    Ecto.QueryError -> []
  end

  def list_auction_returns(filters \\ %{}, current_human \\ nil) do
    limit = Core.normalize_limit(Map.get(filters, :limit), 20)
    offset = Core.normalize_offset(Map.get(filters, :offset), 0)

    items =
      list_auctions(%{mode: "failed_minimum", sort: "failure_recent"}, current_human)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    %{
      items: items,
      limit: limit,
      offset: offset,
      next_offset: if(length(items) == limit, do: offset + limit, else: nil)
    }
  end

  defp filter_auctions(auctions, filters) do
    auctions
    |> maybe_filter_mode(Map.get(filters, :mode, "biddable"))
  end

  defp maybe_filter_mode(auctions, nil), do: Enum.filter(auctions, &(&1.phase == "biddable"))
  defp maybe_filter_mode(auctions, ""), do: Enum.filter(auctions, &(&1.phase == "biddable"))
  defp maybe_filter_mode(auctions, "all"), do: auctions

  defp maybe_filter_mode(auctions, "failed_minimum"),
    do: Enum.filter(auctions, &(&1.auction_outcome == "failed_minimum"))

  defp maybe_filter_mode(auctions, mode), do: Enum.filter(auctions, &(&1.phase == mode))

  defp sort_auctions(auctions, filters) do
    case Map.get(filters, :sort, "newest") do
      "oldest" ->
        Enum.sort_by(auctions, &Core.sort_timestamp(&1.started_at, &1.created_at), :asc)

      "market_cap_desc" ->
        Enum.sort_by(auctions, &Core.market_cap_sort_key(&1.implied_market_cap_usdc, :desc), :asc)

      "market_cap_asc" ->
        Enum.sort_by(auctions, &Core.market_cap_sort_key(&1.implied_market_cap_usdc, :asc), :asc)

      "failure_recent" ->
        Enum.sort_by(auctions, &Core.sort_timestamp(&1.ends_at, &1.created_at), :desc)

      _ ->
        Enum.sort_by(auctions, &Core.sort_timestamp(&1.started_at, &1.created_at), :desc)
    end
  end
end
