defmodule Autolaunch.AuctionFinish.Finish do
  @moduledoc """
  Looks at one running launch. A `migrate` it was already sent is settled
  first, and while the chain has not settled it nothing else happens. Then,
  before its migration block, nothing happens. After it, a launch the chain
  already shows as graduated or failed is marked so, and one still running is
  sent `migrate` from the finishing wallet.

  The chain is read after the settle, so a launch whose `migrate` has just been
  mined is seen finished rather than sent another.
  """

  use Ash.Resource.Change

  require Logger

  alias Autolaunch.AuctionFinish.{Launchpads, Sender}
  alias Autolaunch.Chain.Rpc

  @impl true
  def change(changeset, _opts, _context), do: Ash.Changeset.before_action(changeset, &finish/1)

  defp finish(%{data: finish} = changeset) do
    pad = Launchpads.for_launch!(finish)

    with {:ok, :clear} <- Sender.settle(pad, finish),
         {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, now} <- Launchpads.clock(pad, block),
         {:ok, outcome} <- step(pad, finish, block, now) do
      apply_outcome(changeset, outcome)
    else
      {:ok, :waiting} ->
        changeset

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          "could not finish #{finish.launchpad} launch #{finish.launch_id}: #{inspect(reason)}"
        )
    end
  end

  defp step(_pad, %{migration_block: migration_block}, _block, now) when now < migration_block,
    do: {:ok, :not_yet}

  defp step(pad, finish, block, _now) do
    with {:ok, %{state: state}} <- Launchpads.launch(pad, finish.launch_id, block),
         do: act(pad, finish, state)
  end

  defp act(pad, finish, :running) do
    with {:ok, transaction} <- Sender.send_call(pad, finish, Launchpads.migrate_call(pad, finish)),
         do: {:ok, {:sent, transaction}}
  end

  defp act(_pad, _finish, finished), do: {:ok, {:finished, finished}}

  defp apply_outcome(changeset, :not_yet), do: changeset

  defp apply_outcome(changeset, {:finished, state}),
    do: Ash.Changeset.force_change_attribute(changeset, :state, state)

  defp apply_outcome(%{data: finish} = changeset, {:sent, transaction}) do
    Logger.info(
      "auction finisher sent migrate for #{finish.launchpad} launch #{finish.launch_id}: " <>
        "#{transaction.transaction_hash} (nonce #{transaction.nonce})"
    )

    changeset
  end
end
