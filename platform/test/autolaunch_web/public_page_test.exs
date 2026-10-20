defmodule AutolaunchWeb.PublicPageTest do
  @moduledoc """
  "Load more" on a list, and `next_cursor` in the public API, carry a cursor
  for the next page. A cursor pages on only the list it came from: the same
  filters and search. Under any other filters, or edited, it is refused
  rather than paging a different list from the wrong place.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.HomeMarket
  alias AutolaunchWeb.PublicPage

  defp scope do
    gen all(
          view <- member_of(~w(auctions tokens)),
          state <- member_of(~w(all active graduated)),
          chain <- member_of(~w(all base robinhood)),
          x <- boolean(),
          q <- member_of(["", "frog", "0x12ab"])
        ) do
      options =
        HomeMarket.options(%{
          "view" => view,
          "state" => state,
          "chain" => chain,
          "x" => x,
          "q" => q
        })

      {:home_market, Map.drop(options, [:display])}
    end
  end

  defp cursor(scope, keyset) do
    page = %{more?: true, results: [%{__metadata__: %{keyset: keyset}}]}
    PublicPage.metadata(page, scope).next_cursor
  end

  property "a cursor pages on only the list it came from" do
    check all(
            from <- scope(),
            other <- scope(),
            keyset <- binary(min_length: 1, max_length: 64),
            limit <- integer(1..50)
          ) do
      cursor = cursor(from, keyset)

      assert PublicPage.options(cursor, from, limit) == {:ok, [limit: limit, after: keyset]}

      if other != from,
        do: assert(PublicPage.options(cursor, other, limit) == {:error, :invalid_query})
    end
  end

  property "an edited cursor is refused" do
    check all(
            from <- scope(),
            keyset <- binary(min_length: 1, max_length: 64),
            at <- integer(0..1000),
            byte <- integer(0..255)
          ) do
      cursor = cursor(from, keyset)
      at = rem(at, byte_size(cursor))
      <<head::binary-size(at), original, tail::binary>> = cursor

      # The last character of each part can carry unused bits, so another
      # character there may decode to the same bytes; every other edit counts.
      part_end? = tail == "" or String.starts_with?(tail, ".")

      if byte != original and not part_end? do
        edited = head <> <<byte>> <> tail
        assert PublicPage.options(edited, from, 24) == {:error, :invalid_query}
      end
    end
  end

  test "a list's last page has no cursor, and a cursor longer than 4096 bytes is refused" do
    scope = {:home_market, Map.drop(HomeMarket.options(%{}), [:display])}

    assert PublicPage.metadata(%{more?: false, results: []}, scope) ==
             %{has_more: false, next_cursor: nil}

    assert PublicPage.options(String.duplicate("a", 4097), scope, 24) == {:error, :invalid_query}
  end
end
