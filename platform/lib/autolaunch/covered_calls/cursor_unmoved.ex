defmodule Autolaunch.CoveredCalls.CursorUnmoved do
  @moduledoc """
  Lets a covered-call reader's cursor move only from where its pass found it,
  checked inside the `UPDATE` itself: a pass holding an older copy, as when two
  passes on one contract overlap, gets `Ash.Error.Changes.StaleRecord` and
  writes nothing.
  """
  use Ash.Resource.Validation

  @impl true
  def atomic(changeset, _opts, _context) do
    from = Ash.Changeset.get_argument(changeset, :from)

    {:atomic, [:next_block], expr(next_block != ^from),
     expr(
       error(Ash.Error.Changes.StaleRecord, %{
         resource: "covered_call_cursors",
         filter: %{next_block: ^from}
       })
     )}
  end
end
