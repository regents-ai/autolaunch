defmodule Autolaunch.AgentLaunch.PersonsDraft do
  @moduledoc """
  The draft a paired agent's review names (`launch_draft_id`) is one of its
  person's own: `draft` holds it, read through the agent's own draft read,
  which names only the drafts of the person the pairing names.
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, opts, %{actor: actor}) do
    id = Ash.Changeset.get_attribute(changeset, :launch_draft_id)

    opts[:draft]
    |> Ash.Query.for_read(:agent_read, %{}, actor: actor)
    |> Ash.Query.filter(id == ^id)
    |> Ash.exists()
    |> case do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, field: :launch_draft_id, message: "is not the person's draft"}
      {:error, error} -> {:error, error}
    end
  end
end
