defmodule AutolaunchWeb.AuctionControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  @robinhood_chain_id 4_663

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_robinhood_chain_id)
    Application.put_env(:autolaunch, :autolaunch_robinhood_chain_id, @robinhood_chain_id)
    on_exit(fn -> Application.put_env(:autolaunch, :autolaunch_robinhood_chain_id, previous) end)
  end

  # The public list names every entry by an id; that id opens the entry's
  # detail, Robinhood's included.
  test "a Robinhood auction's id from the list opens its detail", %{conn: conn} do
    TestSupport.project_auction(chain_id: @robinhood_chain_id, state: :active)

    listed = conn |> get("/api/v1/auctions") |> json_response(200)
    assert [%{"chain" => "robinhood", "id" => id} = entry] = listed["data"]

    assert %{"data" => ^entry} = conn |> get("/api/v1/auctions/#{id}") |> json_response(200)
  end

  # The counts the auctions page's band shows, split by chain, for a tracker
  # that would otherwise page the whole list and tally it.
  test "the counts give each launch type's live and graduated auctions on each chain",
       %{conn: conn} do
    revstake = &TestSupport.project_auction(chain_id: 8453, state: &1)
    revstake.(:active)
    revstake.(:graduated)
    revstake.(:graduated)
    revstake.(:failed)

    for state <- [:active, :active, :graduated, :created] do
      stocks_auction(8453, state)
    end

    stocks_auction(@robinhood_chain_id, :active)
    stocks_auction(@robinhood_chain_id, :graduated)

    assert %{
             "data" => %{
               "revstake" => %{"base" => %{"live" => 1, "graduated" => 2}},
               "memestock" => %{
                 "base" => %{"live" => 2, "graduated" => 1},
                 "robinhood" => %{"live" => 1, "graduated" => 1}
               }
             }
           } == conn |> get("/api/v1/auction-counts") |> json_response(200)

    assert %{"error" => %{"code" => "invalid_request"}} =
             conn |> get("/api/v1/auction-counts?chain=base") |> json_response(400)
  end

  defp stocks_auction(chain_id, state),
    do: TestSupport.project_auction(chain_id: chain_id, kind: :stocks, state: state)
end
