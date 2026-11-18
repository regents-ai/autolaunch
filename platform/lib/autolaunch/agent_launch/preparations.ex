defmodule Autolaunch.AgentLaunch.Preparations do
  @kept 20

  @moduledoc """
  A paired agent's reviews (`:agent_prepare` on `Autolaunch.LaunchOperation`
  and `Autolaunch.Stocks.LaunchOperation`, `:agent_record` on
  `Autolaunch.Robinhood.LaunchReview`), kept bounded in the write itself, once
  the pairing is locked (`RegentAgents.RequirePairing`).

  `of` names whose preparations they are (one draft on Base, one person on one
  chain on Robinhood) and `same` what two of them must share to be the same.
  Each resource's `:agent_preparations` read is the agent's reviews that have
  not carried out a launch, newest first.

  When one of those is the same, it is the answer and nothing is written.
  Otherwise the new one is written, and those beyond the latest #{@kept} are
  removed (`:trim`): preparing again for a changed draft keeps the latest
  #{@kept} preparations. A review the person's page saved, and one that carried
  out a launch, are never reused or removed.

  A Base review is the same without the moment it was read: the block, and the
  treasury check's record of that read.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Autolaunch.Actors.System

  @read_at ["block_number", "block_hash"]
  @checked_at ["report_id", "source_block_number", "source_block_hash"]

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&same_or_new(&1, opts))
    |> Ash.Changeset.after_action(&trim(&1, &2, opts))
  end

  defp same_or_new(changeset, opts) do
    content = changeset |> attributes(opts[:same]) |> content()

    case changeset |> preparations(opts) |> Ash.Query.limit(@kept) |> Ash.read() do
      {:ok, kept} ->
        case Enum.find(kept, &(&1 |> Map.take(opts[:same]) |> content() == content)) do
          nil -> changeset
          same -> Ash.Changeset.set_result(changeset, {:ok, same})
        end

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp trim(changeset, kept, opts) do
    changeset
    |> preparations(opts)
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

  defp preparations(changeset, opts) do
    of = changeset |> attributes(opts[:of]) |> Map.to_list()

    changeset.resource
    |> Ash.Query.for_read(:agent_preparations, %{}, actor: %System{})
    |> Ash.Query.filter(^of)
  end

  defp attributes(changeset, names),
    do: Map.new(names, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

  defp content(attributes), do: Map.replace_lazy(attributes, :review, &unread/1)

  defp unread(%{"facts" => facts} = review) do
    facts = Map.drop(facts, @read_at)

    case facts do
      %{"treasury_security" => %{} = check} ->
        %{review | "facts" => %{facts | "treasury_security" => Map.drop(check, @checked_at)}}

      _no_check ->
        %{review | "facts" => facts}
    end
  end
end
