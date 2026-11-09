defmodule AutolaunchWeb.PairLiveTest do
  use ExUnit.Case, async: true

  alias AutolaunchWeb.PairLive

  # PAIR_LINK_STAYS_ON_SITE: a pairing link's page is printed in the message a
  # person pastes to their agent, so only a page on this site is taken; anything a
  # browser could read as another site is dropped and the link opens plain pairing.
  test "PAIR_LINK_STAYS_ON_SITE" do
    for to <- ["/", "/auctions", "/agents/123?tab=stake#lanes"],
        do: assert(PairLive.start(%{"to" => to}) == to)

    for to <- [
          "//example.com",
          "/\\example.com",
          "https://example.com/auctions",
          "javascript:alert(1)",
          "auctions",
          "/auctions now",
          "/auctions\nnow",
          "/auctions\u0000",
          "",
          "/" <> String.duplicate("a", 512),
          ["/auctions"]
        ],
        do: assert(PairLive.start(%{"to" => to}) == nil, inspect(to))

    assert PairLive.start(%{}) == nil
  end
end
