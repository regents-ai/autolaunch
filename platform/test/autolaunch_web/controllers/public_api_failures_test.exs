defmodule AutolaunchWeb.PublicApiFailuresTest do
  @moduledoc """
  The public API answers a failed read with its generic error and logs it,
  naming only the kind and the module of what failed, never the database's
  text. The reads are made to fail by renaming the tables they need, inside
  the case's own transaction.
  """
  use AutolaunchWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.{Repo, TestSupport}
  alias AutolaunchWeb.AuctionController

  @moduletag :capture_log

  test "PUBLIC_API_FAILED_READS_ARE_LOGGED: each failed read is logged by kind and module only",
       %{conn: conn} do
    auction = TestSupport.project_auction(chain_id: 8453, state: :active)

    token =
      TestSupport.project_token(auction_id: auction.id, graduated_at: DateTime.utc_now())

    # A list read moments ago may be kept; this case reads it afresh.
    Cachex.clear(AuctionController.cache())

    for table <- ~w(auctions tokens treasury_security_reports) do
      Repo.query!("ALTER TABLE autolaunch_app.#{table} RENAME TO #{table}_unreadable")
    end

    treasury = "0x" <> String.duplicate("6", 40)

    for {method, path, logged} <- [
          {:get, "/api/v1/auctions", "public auctions read failed: Ash.Error."},
          {:get, "/api/v1/auctions/#{auction.id}", "public auction read failed: Ash.Error."},
          {:post, "/api/v1/auctions/#{auction.id}/bid-quote?amount=1&max_price=1",
           "bid quote read failed: database_unavailable"},
          {:get, "/api/v1/tokens", "public tokens read failed: Ash.Error."},
          {:get, "/api/v1/tokens/#{token.id}", "public token read failed: Ash.Error."},
          {:get, "/api/v1/treasury-security/#{treasury}",
           "treasury report read failed: Ash.Error."}
        ] do
      {answer, log} = with_log(fn -> dispatch(conn, @endpoint, method, path) end)

      assert %{"error" => %{"code" => "internal_error"}} = json_response(answer, 500), path
      assert log =~ logged, "#{path} logged: #{inspect(log)}"
      refute log =~ "_unreadable"
      refute log =~ "42P01"
    end
  end
end
