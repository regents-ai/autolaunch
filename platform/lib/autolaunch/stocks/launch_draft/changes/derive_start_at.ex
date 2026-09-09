defmodule Autolaunch.Stocks.LaunchDraft.Changes.DeriveStartAt do
  @moduledoc false
  use Ash.Resource.Change

  alias Ash.Error.Changes.InvalidArgument
  alias Autolaunch.Stocks.LaunchDraft

  # `start_local` is the wall-clock text a `datetime-local` control produces
  # (`YYYY-MM-DDTHH:MM`, seconds optional). Together with the IANA zone it was
  # entered in, it names one exact instant; that instant is what is stored.
  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_argument(changeset, :start_local) do
      {:ok, local} ->
        derive(changeset, local, Ash.Changeset.get_attribute(changeset, :start_timezone))

      :error ->
        changeset
    end
  end

  defp derive(changeset, local, _zone) when local in [nil, ""],
    do: Ash.Changeset.force_change_attribute(changeset, :start_at, nil)

  defp derive(changeset, local, zone) do
    with true <- LaunchDraft.timezone?(zone),
         {:ok, naive} <- NaiveDateTime.from_iso8601(normalize(local)),
         {:ok, zoned} <- DateTime.from_naive(naive, zone),
         {:ok, utc} <- DateTime.shift_zone(zoned, "Etc/UTC") do
      Ash.Changeset.force_change_attribute(changeset, :start_at, DateTime.truncate(utc, :second))
    else
      {:ambiguous, first, _second} ->
        {:ok, utc} = DateTime.shift_zone(first, "Etc/UTC")

        Ash.Changeset.force_change_attribute(
          changeset,
          :start_at,
          DateTime.truncate(utc, :second)
        )

      {:gap, _before, after_gap} ->
        {:ok, utc} = DateTime.shift_zone(after_gap, "Etc/UTC")

        Ash.Changeset.force_change_attribute(
          changeset,
          :start_at,
          DateTime.truncate(utc, :second)
        )

      false ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: :start_timezone, message: "is not a known time zone")
        )

      _invalid ->
        Ash.Changeset.add_error(
          changeset,
          InvalidArgument.exception(field: :start_local, message: "must be a date and time")
        )
    end
  end

  # `YYYY-MM-DDTHH:MM` gains the seconds ISO 8601 parsing requires.
  defp normalize(local) do
    case String.split(local, ":") do
      [_date_hour, _minute] -> local <> ":00"
      _other -> local
    end
  end
end
