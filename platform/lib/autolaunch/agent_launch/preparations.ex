defmodule Autolaunch.AgentLaunch.Preparations do
  @kept 20
  @good_for_hours 24

  @moduledoc """
  A paired agent's reviews (`:agent_prepare` on `Autolaunch.LaunchOperation`
  and `Autolaunch.Stocks.LaunchOperation`, `:agent_record` on
  `Autolaunch.Robinhood.LaunchReview`), kept bounded in the write itself, once
  the pairing is locked (`RegentAgents.RequirePairing`).

  `of` names whose preparations they are (one draft on Base, one person on one
  chain on Robinhood) and `same` what two of them must share to be the same.
  Each resource's `:agent_preparations` read is the agent's open reviews, those
  that have not carried out a launch, newest first.

  When the newest open one is the same, it is the answer and nothing is
  written; an older one that is the same is not, so the newest is always the
  agent's latest preparation, which a listing takes first. Otherwise the new
  one is written. Each open one stays good for #{@good_for_hours} hours, so its
  step can still be signed and listed, and at most #{@kept} are kept: to make
  room, the oldest of those past #{@good_for_hours} hours are removed first
  (`:trim`), and with too few of them the new one is refused
  (`:too_many_preparations`) and nothing changes. A review the person's page
  saved, and one that carried out a launch, are never reused or removed.

  The open ones are read locked, newest first, so two of the person's agents
  preparing at once lock them in one order and never wait on each other in a
  cycle. The one that waits sees what the other removed but not what it wrote,
  so for a moment a scope can hold one more than #{@kept}, or the same one
  twice; the next new one trims the extra, and the same one again is the
  newest.

  A Base review is the same without the moment it was read: the block, and the
  treasury check's record of that read.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Ash.Error.Invalid.Unavailable
  alias Autolaunch.Actors.System

  @read_at ["block_number", "block_hash"]
  @checked_at ["report_id", "source_block_number", "source_block_hash"]

  @impl true
  def change(changeset, opts, _context),
    do: Ash.Changeset.before_action(changeset, &same_or_new(&1, opts))

  defp same_or_new(changeset, opts) do
    case changeset |> preparations(opts) |> Ash.Query.lock(:for_update) |> Ash.read() do
      {:ok, [newest | _] = open} ->
        if same?(changeset, newest, opts),
          do: Ash.Changeset.set_result(changeset, {:ok, newest}),
          else: room(changeset, open, opts)

      {:ok, []} ->
        changeset

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # Room for the new one beside at most @kept - 1 open ones: the oldest of
  # those past their @good_for_hours hours go, as many as must.
  defp room(changeset, open, opts) do
    over = length(open) - (@kept - 1)
    since = DateTime.add(DateTime.utc_now(), -@good_for_hours, :hour)
    lapsed = open |> Enum.reverse() |> Enum.take_while(&DateTime.before?(&1.inserted_at, since))

    cond do
      over <= 0 ->
        changeset

      length(lapsed) < over ->
        Ash.Changeset.add_error(
          changeset,
          Unavailable.exception(resource: changeset.resource, reason: :too_many_preparations)
        )

      true ->
        trim(changeset, Enum.take(lapsed, over), opts)
    end
  end

  # Only while each is still open as the removal runs.
  defp trim(changeset, lapsed, opts) do
    ids = Enum.map(lapsed, & &1.id)

    changeset
    |> preparations(opts)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.bulk_destroy(:trim, %{}, actor: %System{}, strategy: :atomic, return_errors?: true)
    |> case do
      %Ash.BulkResult{status: :success} -> changeset
      %Ash.BulkResult{errors: errors} -> Ash.Changeset.add_error(changeset, errors)
    end
  end

  defp preparations(changeset, opts) do
    of = changeset |> attributes(opts[:of]) |> Map.to_list()

    changeset.resource
    |> Ash.Query.for_read(:agent_preparations, %{}, actor: %System{})
    |> Ash.Query.filter(^of)
  end

  defp same?(changeset, newest, opts),
    do:
      newest |> Map.take(opts[:same]) |> content() ==
        changeset |> attributes(opts[:same]) |> content()

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
