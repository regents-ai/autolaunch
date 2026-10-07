defmodule AutolaunchWeb.DraftMarks do
  @moduledoc """
  What both create pages mark beside a field whose text is saved as typed but
  that a launch cannot use yet: a link that is not a link of its kind, or a
  ticker outside the ticker rule. A field the save itself refused keeps that
  message instead. And what a draft still needs before its launch review.
  """

  alias Autolaunch.{LaunchLinks, Ticker}

  @doc "The field messages for the form's current values, by field name."
  @spec marked(map(), map()) :: %{String.t() => String.t()}
  def marked(errors, values) do
    links = Map.new(LaunchLinks.fields(), &{&1, values[Atom.to_string(&1)]})
    symbol = values["symbol"]

    LaunchLinks.problems(links)
    |> Map.new(fn {field, hint} -> {Atom.to_string(field), hint} end)
    |> then(fn marks ->
      if symbol in [nil, ""] or Ticker.complete?(symbol),
        do: marks,
        else: Map.put(marks, "symbol", Ticker.hint())
    end)
    |> Map.merge(errors)
  end

  @missing_labels %{
    name: "name",
    symbol: "ticker",
    description: "description",
    website: "website",
    telegram: "a t.me Telegram link",
    discord: "a Discord invite link",
    other_link_1: "a full https:// link",
    other_link_2: "a full https:// link",
    other_link_3: "a full https:// link",
    image: "image",
    stock_address: "paired stock"
  }

  @doc "What a draft still needs, as the Memestake page's Still needed button names it."
  @spec still_needed([atom()]) :: String.t()
  def still_needed(fields) do
    labels = Enum.map(fields, &Map.fetch!(@missing_labels, &1))

    case Enum.split(labels, -1) do
      {[], [only]} -> only
      {rest, [last]} -> Enum.join(rest, ", ") <> " and " <> last
    end
  end
end
