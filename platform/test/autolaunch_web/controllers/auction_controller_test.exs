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
end
