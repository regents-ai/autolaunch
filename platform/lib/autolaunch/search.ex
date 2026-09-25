defmodule Autolaunch.Search do
  @moduledoc """
  The gallery search, shared by the header field, auctions and tokens. A search
  is split into words and a record matches when every word appears somewhere
  in it; a `$` in front of a word, as in `$BITE`, is ignored.
  """

  @limit 80

  @doc "The one form a search takes: single spaces, no spaces at either end, at most eighty characters."
  @spec normalize(term()) :: String.t()
  def normalize(value) when is_binary(value) do
    value
    |> String.split()
    |> Enum.join(" ")
    |> String.graphemes()
    |> Enum.take(@limit)
    |> Enum.join()
  end

  def normalize(_value), do: ""

  @doc "One case-insensitive `ilike` pattern per word of `search`, each matching that word anywhere."
  @spec word_patterns(String.t()) :: [String.t()]
  def word_patterns(search) do
    search
    |> String.downcase()
    |> String.split()
    |> Enum.map(&String.trim_leading(&1, "$"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&("%" <> escape(&1) <> "%"))
  end

  defp escape(word) do
    word
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
