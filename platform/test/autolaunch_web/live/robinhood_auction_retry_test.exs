defmodule AutolaunchWeb.RobinhoodAuctionRetryTest do
  @moduledoc """
  A Robinhood auction page whose auction could not be read as the page opened
  offers Retry. Pressing it once the auction can be read again shows the
  auction, with its chain reading started as it is when the page opens.

  The failed first read is made by renaming the auctions table as the page's
  own read of the auction starts, inside the case's sandboxed transaction;
  putting the name back is the database answering again.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.{Auction, Repo, TestSupport}
  alias AutolaunchWeb.Paths

  @moduletag :capture_log

  @chain_id 4_663

  setup do
    # The site as it runs once launches are open, when a page's buttons work.
    put_env(:prelaunch_read_only, false)
    put_env(:autolaunch_robinhood_chain_id, @chain_id)

    put_env(
      :autolaunch_robinhood_deployment,
      Path.expand("../../fixtures/robinhood-deployment.json", __DIR__)
    )
  end

  test "Retry after a failed first read shows the auction", %{conn: conn} do
    stored = TestSupport.project_auction(chain_id: @chain_id, kind: :stocks, symbol: "RETRY")
    {:ok, auction} = Paths.find_auction("RETRY", String.slice(stored.auction_address, -5, 5))

    conn = get(conn, Paths.auction(auction))
    unreadable_when_the_page_reads()
    {:ok, view, _html} = live(conn)

    assert has_element?(view, "#autolaunch-robinhood-auction[role=alert] button", "Retry")

    Repo.query!("ALTER TABLE autolaunch_app.auctions_unreadable RENAME TO auctions")
    view |> element("#autolaunch-robinhood-auction button", "Retry") |> render_click()

    assert has_element?(view, "article#autolaunch-robinhood-auction h1", "RETRY")
    assert has_element?(view, "article#autolaunch-robinhood-auction .auction-next-overview")
  end

  # The page's own read of its auction, the first after the address was found,
  # finds no table to read.
  defp unreadable_when_the_page_reads do
    handler = "unreadable-#{inspect(self())}"

    :telemetry.attach(
      handler,
      [:ash, :autolaunch, :read, :start],
      fn _event, _measurements, metadata, _config ->
        if metadata.resource == Auction and metadata.action == :robinhood_by_address do
          :telemetry.detach(handler)
          Repo.query!("ALTER TABLE autolaunch_app.auctions RENAME TO auctions_unreadable")
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp put_env(key, value) do
    previous = Application.get_env(:autolaunch, key)
    Application.put_env(:autolaunch, key, value)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, key, previous),
        else: Application.delete_env(:autolaunch, key)
    end)
  end
end
