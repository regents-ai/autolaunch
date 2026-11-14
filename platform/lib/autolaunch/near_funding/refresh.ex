defmodule Autolaunch.NearFunding.Refresh do
  @moduledoc """
  Reads a funding's swap status from the 1Click service once and stores it; a
  change of state is broadcast on `"near_funding:<id>"` as
  `{:near_funding, funding}`.
  """
  use Ash.Resource.Change

  alias Autolaunch.NearFunding.Intents

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&status/1)
    |> Ash.Changeset.after_action(fn changeset, funding ->
      if Ash.Changeset.changing_attribute?(changeset, :state) do
        Phoenix.PubSub.broadcast(
          Autolaunch.PubSub,
          "near_funding:#{funding.id}",
          {:near_funding, funding}
        )
      end

      {:ok, funding}
    end)
  end

  defp status(changeset) do
    case Intents.status(changeset.data.deposit_address) do
      {:ok, status} ->
        Ash.Changeset.force_change_attributes(changeset, status)

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Unknown.UnknownError.exception(error: reason)
        )
    end
  end
end
