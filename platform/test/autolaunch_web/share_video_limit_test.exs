defmodule AutolaunchWeb.ShareVideoLimitTest do
  @moduledoc """
  Once the site has made all of the day's videos, a signed-in person with no
  video saved who asks for their own is refused, and the refusal carries the
  line the share window shows them.
  """
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Repo
  alias Autolaunch.TestSupport
  alias AutolaunchWeb.{Paths, ShareVideo}

  @moduletag :capture_log

  @daily 1000

  test "a person's own video is refused with a line to show once the day's videos are made",
       %{conn: conn} do
    account = TestSupport.register_creator!()

    stored =
      TestSupport.project_auction(
        chain_id: 8453,
        kind: :agent,
        symbol: "FULL",
        state: :graduated,
        token_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
      )

    TestSupport.project_token(
      auction_id: stored.id,
      name: "Full Day",
      symbol: "FULL",
      graduated_at: DateTime.utc_now()
    )

    {:ok, auction} = Paths.find_auction("FULL", String.slice(stored.auction_address, -5, 5))
    a_day_of_videos(stored.id)

    address =
      URI.parse(ShareVideo.wallet_url(auction, account.wallet_address, DateTime.utc_now()))

    refused =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> get("#{address.path}?#{address.query}")

    assert %{"message" => line} = json_response(refused, 429)
    assert is_binary(line) and String.trim(line) != ""
  end

  # A day's worth of other people's videos, already made.
  defp a_day_of_videos(auction_id) do
    rows =
      for n <- 1..@daily do
        %{
          id: Ecto.UUID.bingenerate(),
          kind: "auction",
          auction_id: Ecto.UUID.dump!(auction_id),
          key: "#{auction_id}:filler:#{n}",
          human_account_id: 999_999_999,
          wallet: "0x" <> String.duplicate("f", 40),
          state: "ready"
        }
      end

    Repo.insert_all("share_video_requests", rows)
  end
end
