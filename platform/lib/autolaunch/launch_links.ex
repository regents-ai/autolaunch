defmodule Autolaunch.LaunchLinks do
  @moduledoc """
  The links a creator may add beside a launch's website: a Telegram group, a
  Discord invite and up to three other links. This site keeps them and shows
  them on the launch's auction and token pages; they are not written into the
  token. Each is optional, and one that is filled in must be a link of its
  kind before the launch can be reviewed.
  """

  @others [:other_link_1, :other_link_2, :other_link_3]
  @fields [:telegram, :discord | @others]

  @patterns %{
    telegram: ~r{\Ahttps://t\.me/[A-Za-z0-9_+/-]+\z},
    discord: ~r{\Ahttps://(discord\.gg|discord\.com/invite)/[A-Za-z0-9-]+\z}
  }

  @hints %{
    telegram: "Use a link that starts with https://t.me/",
    discord: "Use an invite link that starts with https://discord.gg/"
  }

  @other_hint "Use a full link that starts with https://"

  @doc "The draft fields that hold links, in the order the page shows them."
  def fields, do: @fields

  @doc "The filled-in links that are not yet links of their kind, each with what to fix."
  @spec problems(map()) :: [{atom(), String.t()}]
  def problems(draft) do
    for field <- @fields, problem?(field, Map.get(draft, field)), do: {field, hint(field)}
  end

  defp problem?(_field, value) when value in [nil, ""], do: false
  defp problem?(field, value), do: not link?(field, value)

  @doc "The other links a draft names, in order, without the empty ones."
  @spec others(map()) :: [String.t()]
  def others(draft),
    do: @others |> Enum.map(&Map.get(draft, &1)) |> Enum.reject(&(&1 in [nil, ""]))

  defp link?(field, value) when field in [:telegram, :discord],
    do: byte_size(value) <= 256 and value =~ Map.fetch!(@patterns, field)

  defp link?(_other, value) do
    byte_size(value) <= 256 and
      match?(%URI{scheme: "https", host: host} when host not in [nil, ""], URI.parse(value)) and
      not String.contains?(value, [" ", "\n", "\t"])
  end

  defp hint(field), do: Map.get(@hints, field, @other_hint)
end
