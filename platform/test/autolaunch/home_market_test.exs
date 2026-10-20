defmodule Autolaunch.HomeMarketTest do
  @moduledoc """
  A list's filters live in its address, so a person can share the list they
  are looking at. Whatever a visitor or a pasted link puts in the address, the
  list's own link for it reads back as the same list, on the home page,
  `/auctions` and `/tokens`. The search box keeps one form of the text it is
  given, so a search reads back the same way.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autolaunch.{HomeMarket, Search}

  # Each key the lists read, with every value they accept and a few they don't.
  @choices %{
    "view" => ~w(auctions tokens grid),
    "sort" => ~w(newest ending volume oldest),
    "display" => ~w(list grid table),
    "state" => ~w(all created active ended failed graduated finished live),
    "chain" => ~w(all base robinhood solana),
    "kind" => ~w(all revstake memestock stocks),
    "x" => ["true", "false", "on", true, false],
    "ens" => ["true", "false", "on", true, false],
    "github" => ["true", "false", "on", true, false]
  }

  # Text a visitor might type or paste: words and spaces, with control
  # characters, hidden direction marks and bytes that are not text among them.
  defp search_text do
    piece =
      one_of([
        string(:alphanumeric, min_length: 1, max_length: 12),
        member_of([
          " ",
          "  ",
          "\t",
          "\n",
          <<0>>,
          <<0x85::utf8>>,
          <<0x202E::utf8>>,
          <<0x2066::utf8>>,
          <<0xFF>>
        ]),
        string(:printable, max_length: 6)
      ])

    gen(all(pieces <- list_of(piece, max_length: 40), do: Enum.join(pieces)))
  end

  defp list_params do
    gen all(
          picked <- list_of(member_of(Map.keys(@choices)), max_length: 9),
          values <- fixed_list(Enum.map(picked, &member_of(@choices[&1]))),
          q <- one_of([constant(nil), search_text()])
        ) do
      picked
      |> Enum.zip(values)
      |> Map.new()
      |> then(&if(q, do: Map.put(&1, "q", q), else: &1))
    end
  end

  # What a page reads from an address: the home page reads it as it is, and
  # /auctions and /tokens name their own view.
  defp read_back(path) do
    uri = URI.parse(path)
    params = URI.decode_query(uri.query || "")

    case uri.path do
      "/" -> HomeMarket.options(params)
      "/auctions" -> params |> Map.put("view", "auctions") |> HomeMarket.options()
      "/tokens" -> params |> Map.put("view", "tokens") |> HomeMarket.options()
    end
  end

  property "the search box keeps one tidy form of any text" do
    check all(text <- search_text(), max_runs: 500) do
      search = Search.normalize(text)

      assert String.valid?(search)
      assert String.trim(search) == search
      refute search =~ "  "
      refute search =~ ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
      assert String.length(search) <= 80
      assert Search.normalize(search) == search
    end
  end

  property "a list's link reads back as the same list" do
    check all(params <- list_params(), max_runs: 500) do
      options = HomeMarket.options(params)
      own_page = if options.view == "tokens", do: "/tokens", else: "/auctions"

      for base <- ["/", own_page] do
        assert read_back(HomeMarket.path(options, %{}, base)) == options
      end
    end
  end
end
