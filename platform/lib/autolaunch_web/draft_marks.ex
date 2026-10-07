defmodule AutolaunchWeb.DraftMarks do
  @moduledoc """
  What both create pages mark beside a field whose text is saved as typed but
  that a launch cannot use yet: a link that is not a link of its kind, or a
  ticker outside the ticker rule. A field the save itself refused keeps that
  message instead.
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
end
