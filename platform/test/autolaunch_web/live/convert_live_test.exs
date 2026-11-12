defmodule AutolaunchWeb.ConvertLiveTest do
  @moduledoc """
  The REGENT Fees page lists every graduated launch even when a launch's fees
  take too long to read from the chain: that launch's row says its fees could
  not be read, and the list stays on the page.

  The chain here is a stand-in that never answers, and the time a read is
  given is the short one the tests are configured with.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.TestSupport

  @moduletag :capture_log

  defmodule SilentChain do
    @moduledoc "A chain that never answers."
    def post(_url, _options), do: Process.sleep(:infinity)
  end

  setup do
    previous = Application.get_env(:autolaunch, :autolaunch_lab_http_client)
    Application.put_env(:autolaunch, :autolaunch_lab_http_client, SilentChain)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:autolaunch, :autolaunch_lab_http_client, previous),
        else: Application.delete_env(:autolaunch, :autolaunch_lab_http_client)
    end)
  end

  test "a launch whose fees take too long to read is listed as unread", %{conn: conn} do
    launches =
      for symbol <- ["SLOWA", "SLOWB"] do
        auction =
          TestSupport.project_auction(
            chain_id: 8453,
            kind: :stocks,
            symbol: symbol,
            state: :graduated
          )

        TestSupport.project_token(
          auction_id: auction.id,
          name: "Launch #{symbol}",
          symbol: symbol,
          graduated_at: DateTime.utc_now()
        )

        {auction.id, "Launch #{symbol}"}
      end

    {:ok, view, _html} = live(conn, "/convert")
    render_async(view, 5_000)

    for {id, name} <- launches do
      assert has_element?(view, "#convert-base-#{id}-row h3", name)
      assert has_element?(view, "#convert-base-#{id}-row [role=alert]")
    end
  end
end
