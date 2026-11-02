defmodule Autolaunch.Auction.Changes.AnnounceListing do
  @moduledoc """
  Emits `:launch_listed` when this write inserted the auction for an account.
  A later writer of the same launch skips the upsert, and Ash marks the row it
  returns with `upsert_skipped`; a launch recorded from the chain alone names
  no account.
  """

  use Ash.Resource.Change

  alias Autolaunch.Signals

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn
      _changeset, %{__metadata__: %{upsert_skipped: true}} = auction ->
        {:ok, auction}

      _changeset, %{creator_human_account_id: nil} = auction ->
        {:ok, auction}

      changeset, auction ->
        with :ok <-
               Ash.Signals.emit(changeset, Signals, :launch_listed, %{auction_id: auction.id}),
             do: {:ok, auction}
    end)
  end
end
