defmodule Autolaunch.AgentLaunch.Preparations do
  @kept 20

  @moduledoc """
  A paired agent's reviews of one draft (`:agent_prepare` on
  `Autolaunch.LaunchOperation` and `Autolaunch.Stocks.LaunchOperation`), kept
  bounded in the write itself, once the pairing is locked
  (`RegentAgents.RequirePairing`).

  When the draft already has a review of the agent's that the chain has not
  shown, with the same content, that review is the answer and nothing is
  written. Otherwise the new one is written, and those beyond the latest
  #{@kept} are removed: preparing again for a changed draft keeps the latest
  #{@kept} preparations. A review the person's page saved, and one the chain
  has shown, are never reused or removed.

  The content is what the wallet is asked to send and what the launch is listed
  with, without the moment it was read: the block, and the treasury check's
  record of that read.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Autolaunch.Actors.System

  @read_at ["block_number", "block_hash"]
  @checked_at ["report_id", "source_block_number", "source_block_hash"]

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&same_or_new/1)
    |> Ash.Changeset.after_action(&trim/2)
  end

  defp same_or_new(changeset) do
    draft = Ash.Changeset.get_attribute(changeset, :launch_draft_id)
    content = content(Ash.Changeset.get_attribute(changeset, :review))

    case changeset.resource |> preparations(draft) |> Ash.Query.limit(@kept) |> read() do
      {:ok, kept} ->
        case Enum.find(kept, &(content(&1.review) == content)) do
          nil -> changeset
          same -> Ash.Changeset.set_result(changeset, {:ok, same})
        end

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp trim(changeset, kept) do
    changeset.resource
    |> preparations(kept.launch_draft_id)
    |> Ash.Query.offset(@kept)
    |> Ash.bulk_destroy(:trim, %{},
      actor: %System{},
      strategy: [:atomic, :stream],
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> {:ok, kept}
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  # The draft's reviews an agent prepared that the chain has not shown, newest
  # first.
  defp preparations(resource, draft) do
    resource
    |> Ash.Query.filter(
      launch_draft_id == ^draft and prepared_by == :agent and state == :prepared
    )
    |> Ash.Query.sort(inserted_at: :desc)
  end

  defp read(query), do: Ash.read(query, actor: %System{})

  defp content(%{"facts" => facts} = review) do
    facts = Map.drop(facts, @read_at)

    case facts do
      %{"treasury_security" => %{} = check} ->
        %{review | "facts" => %{facts | "treasury_security" => Map.drop(check, @checked_at)}}

      _no_check ->
        %{review | "facts" => facts}
    end
  end
end
