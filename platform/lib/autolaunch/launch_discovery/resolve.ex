defmodule Autolaunch.LaunchDiscovery.Resolve do
  @moduledoc """
  Matches one pending launch to the review it carried out and lists it for that
  review's account, or keeps it pending with the reason the chain could not
  answer yet. A Memestock launch no review of this site carried out is listed
  from the chain under its launching wallet (`Autolaunch.Stocks.ChainLaunch`);
  a Revstake one is left unlisted.
  """

  use Ash.Resource.Change

  alias Autolaunch.LaunchReviews
  alias Autolaunch.Stocks.ChainLaunch

  @kinds %{base_revstake: :launch, base_memestock: :stocks_launch}

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &resolve/1)

  defp resolve(%{data: discovery} = changeset) do
    @kinds
    |> Map.fetch!(discovery.launchpad)
    |> LaunchReviews.recover(discovery)
    |> from_chain(discovery)
    |> record(changeset)
  end

  # A site review's launch sent from a wallet other than the review's signer
  # matches no review, so it too is listed here, under the wallet that sent it.
  defp from_chain({:unlisted, :no_matching_review}, %{launchpad: :base_memestock} = discovery),
    do: ChainLaunch.list(discovery)

  defp from_chain(answer, _discovery), do: answer

  defp record({:listed, account_id, _result}, changeset),
    do:
      Ash.Changeset.force_change_attributes(changeset,
        state: :listed,
        creator_human_account_id: account_id,
        reason: nil
      )

  defp record({:unlisted, reason}, changeset),
    do: Ash.Changeset.force_change_attributes(changeset, state: :unlisted, reason: text(reason))

  # A launch taken again from `unlisted` waits as `pending`, so the next pass
  # takes it once more.
  defp record({:pending, reason}, changeset),
    do: Ash.Changeset.force_change_attributes(changeset, state: :pending, reason: text(reason))

  defp text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp text(reason), do: reason |> inspect() |> String.slice(0, 120)
end
