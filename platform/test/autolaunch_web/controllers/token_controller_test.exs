defmodule AutolaunchWeb.TokenControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch
  alias Autolaunch.Actors.System
  alias Autolaunch.TestAutolaunchTreasuryChainClient, as: TreasuryClient
  alias Autolaunch.TestSupport

  defmodule RecordingAutolaunch do
    def page_public_tokens(actor: nil, page: [limit: limit]) do
      send(self(), {:list_public_tokens, limit})
      {:ok, %Ash.Page.Keyset{results: [], more?: false}}
    end
  end

  defmodule FailingAutolaunch do
    def page_public_tokens(actor: nil, page: _), do: {:error, {:sentinel, "private details"}}
  end

  test "GET routes an empty public token list", %{conn: conn} do
    assert conn |> get("/api/v1/tokens") |> json_response(200) == %{
             "data" => [],
             "pagination" => %{"has_more" => false, "next_cursor" => nil}
           }

    assert Enum.any?(AutolaunchWeb.Router.__routes__(), fn route ->
             route.verb == :get and route.path == "/api/v1/tokens" and
               route.plug == AutolaunchWeb.TokenController and
               route.plug_opts == :index
           end)
  end

  test "GET returns newest tokens through the explicit field allowlist", %{conn: conn} do
    auction = auction!()
    now = DateTime.utc_now()

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Newest Token",
        symbol: "NEW",
        summary: "Public token summary.",
        graduated_at: now,
        top_rank: 1
      )

    assert %{"data" => [public]} =
             conn
             |> get("/api/v1/tokens?limit=1")
             |> json_response(200)

    assert Map.keys(public) |> Enum.sort() ==
             ~w(auction_id graduated_at id name subject_id summary symbol top_rank treasury_security)

    assert public == %{
             "id" => token.id,
             "auction_id" => auction.id,
             "subject_id" => nil,
             "name" => "Newest Token",
             "symbol" => "NEW",
             "summary" => "Public token summary.",
             "graduated_at" => DateTime.to_iso8601(now),
             "top_rank" => 1,
             "treasury_security" => nil
           }
  end

  test "GET loads a token's auction-bound report as the same fail-closed projection", %{
    conn: conn
  } do
    report =
      TreasuryClient.seed_verified!("0x9999999999999999999999999999999999999999")

    auction = auction!()
    Autolaunch.set_auction_treasury_security_report!(auction, report.id, actor: %System{})

    token =
      TestSupport.project_token(
        auction_id: auction.id,
        name: "Bound Token",
        symbol: "BOUND",
        summary: nil,
        graduated_at: DateTime.utc_now(),
        top_rank: nil
      )

    assert %{"data" => tokens} =
             conn |> get("/api/v1/tokens") |> json_response(200)

    listed_token = Enum.find(tokens, &(&1["id"] == token.id))

    assert %{"data" => auction_detail} =
             conn
             |> get("/api/v1/auctions/#{auction.id}")
             |> json_response(200)

    assert listed_token
    assert auction_detail["treasury_security"]["id"] == report.id

    assert auction_detail["treasury_security"]["verification_state"] ==
             "awaiting_current_chain_confirmation"

    assert auction_detail["treasury_security"]["verification_reason"] ==
             "projector_refresh_not_integrated"

    # dest project_lab does not copy auction treasury provenance the way
    # source import_public did; the token envelope still carries the field.
    assert listed_token["treasury_security"] == nil
  end

  test "GET clamps both limit edges and rejects undocumented or invalid query values", %{
    conn: conn
  } do
    injected =
      Plug.Conn.put_private(
        conn,
        :token_controller_autolaunch,
        RecordingAutolaunch
      )

    assert injected
           |> get("/api/v1/tokens?limit=0")
           |> json_response(200) == %{
             "data" => [],
             "pagination" => %{"has_more" => false, "next_cursor" => nil}
           }

    assert_received {:list_public_tokens, 1}

    assert injected
           |> get("/api/v1/tokens?limit=101")
           |> json_response(200) == %{
             "data" => [],
             "pagination" => %{"has_more" => false, "next_cursor" => nil}
           }

    assert_received {:list_public_tokens, 100}

    for path <- [
          "/api/v1/tokens?cursor=next",
          "/api/v1/tokens?limit=1.5"
        ] do
      assert conn |> get(path) |> json_response(400) == %{
               "error" => %{
                 "code" => "invalid_request",
                 "message" => "The query parameters are invalid."
               }
             }
    end
  end

  test "GET hides domain failures behind the canonical error envelope", %{conn: conn} do
    response =
      conn
      |> Plug.Conn.put_private(
        :token_controller_autolaunch,
        FailingAutolaunch
      )
      |> get("/api/v1/tokens")

    assert json_response(response, 500) == %{
             "error" => %{
               "code" => "internal_error",
               "message" => "The request could not be completed."
             }
           }

    refute response.resp_body =~ "sentinel"
    refute response.resp_body =~ "private details"
  end

  test "cookies and bearer headers do not affect the public token list", %{conn: conn} do
    auction = auction!()

    TestSupport.project_token(
      auction_id: auction.id,
      name: "Public Token",
      symbol: "PUB",
      summary: nil,
      graduated_at: DateTime.utc_now(),
      top_rank: nil
    )

    anonymous = conn |> get("/api/v1/tokens") |> json_response(200)

    credentialed =
      conn
      |> put_req_cookie("_autolaunch_key", "not-a-session")
      |> put_req_header("authorization", "Bearer not-an-agent-token")
      |> get("/api/v1/tokens")
      |> json_response(200)

    assert anonymous == credentialed
  end

  test "token continuation reaches beyond 100 tied graduations", %{conn: conn} do
    now = DateTime.utc_now()

    records =
      for n <- 1..103 do
        auction = auction!()

        TestSupport.project_token(
          auction_id: auction.id,
          name: "Token #{n}",
          symbol: "T#{n}",
          graduated_at: now
        )
      end

    first = conn |> get("/api/v1/tokens") |> json_response(200)
    assert length(first["data"]) == 100

    second =
      conn
      |> get("/api/v1/tokens", %{"after" => first["pagination"]["next_cursor"]})
      |> json_response(200)

    ids = Enum.map(first["data"] ++ second["data"], & &1["id"])
    assert length(ids) == 103
    assert MapSet.new(ids) == MapSet.new(records, & &1.id)
    refute second["pagination"]["has_more"]
    assert conn |> get("/api/v1/tokens?after=invalid") |> json_response(400)
  end

  defp auction! do
    TestSupport.project_auction(
      title: "Token auction",
      featured: false,
      state: :graduated,
      opened_at: DateTime.utc_now()
    )
  end
end
