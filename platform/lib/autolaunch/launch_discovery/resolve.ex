defmodule Autolaunch.LaunchDiscovery.Resolve do
  @moduledoc """
  Matches one pending launch to the review it carried out and lists it for that
  review's account, leaves it unlisted when no review of this site carried it
  out, or keeps it pending with the reason the chain could not answer yet.
  """

  use Ash.Resource.Change

  alias Autolaunch.WalletAttempts

  @kinds %{base_revstake: :launch, base_memestake: :stocks_launch}

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &resolve/1)

  defp resolve(%{data: discovery} = changeset) do
    @kinds
    |> Map.fetch!(discovery.launchpad)
    |> WalletAttempts.recover_launch(discovery)
    |> record(changeset)
  end

  defp record({:listed, account_id}, changeset),
    do:
      Ash.Changeset.force_change_attributes(changeset,
        state: :listed,
        creator_human_account_id: account_id,
        reason: nil
      )

  defp record({:unlisted, reason}, changeset),
    do: Ash.Changeset.force_change_attributes(changeset, state: :unlisted, reason: text(reason))

  defp record({:pending, reason}, changeset),
    do: Ash.Changeset.force_change_attribute(changeset, :reason, text(reason))

  defp text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp text(reason), do: reason |> inspect() |> String.slice(0, 120)
end
