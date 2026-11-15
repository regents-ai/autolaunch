defmodule Autolaunch.CoveredCalls.CursorUnmoved do
  @moduledoc """
  Lets a covered-call reader's cursor move only from where its pass found it,
  and never while it is stopped, checked inside the `UPDATE` itself: a pass
  holding an older copy, or one running while an operator cleared a stop, gets
  `Ash.Error.Changes.StaleRecord` and writes nothing.
  """
  use Ash.Resource.Validation

  @impl true
  def atomic(changeset, _opts, _context) do
    from = Ash.Changeset.get_argument(changeset, :from)

    {:atomic, [:next_block, :rescan_from], expr(next_block != ^from or not is_nil(rescan_from)),
     expr(
       error(Ash.Error.Changes.StaleRecord, %{
         resource: "covered_call_cursors",
         filter: %{next_block: ^from}
       })
     )}
  end
end
