defmodule AutolaunchWeb.AgentAccountController do
  @moduledoc "Signed private reads and metadata-only draft edits; no wallet or launch authority."
  use AutolaunchWeb, :controller
  alias AutolaunchWeb.ApiError
  alias RegentPoints.{Amount, Rules}

  @points_off "Earning Points is off on this site."
  @spending_off "Approving agent spending is off on this site."

  @fields ~w(name symbol description website telegram discord other_link_1 other_link_2 other_link_3)
  plug AutolaunchWeb.Plugs.AgentAccess

  def positions(conn, params), do: AutolaunchWeb.MyPositionsController.signed(conn, params)

  def draft(conn, %{"kind" => kind}) do
    with {:ok, resource} <- resource(kind),
         {:ok, draft} <- read_draft(resource, conn.assigns.actor) do
      json(conn, %{data: present(draft), kind: kind})
    else
      _ -> unavailable(conn)
    end
  end

  def save_draft(conn, %{"kind" => kind}) do
    params = conn.body_params

    if is_map(params) and map_size(params) > 0 and
         Enum.all?(params, fn {key, value} -> key in @fields and is_binary(value) end) do
      save(conn, kind, params)
    else
      ApiError.send(
        conn,
        :unprocessable_entity,
        "invalid_draft",
        "Send token metadata only. Treasury, chain, launch terms and wallet fields are not accepted."
      )
    end
  end

  defp save(conn, kind, params) do
    actor = conn.assigns.actor

    with {:ok, resource} <- resource(kind),
         {:ok, draft} <-
           Autolaunch.Repo.transaction(fn -> save_metadata(resource, actor, params) end) do
      json(conn, %{data: present(draft), kind: kind})
    else
      _ ->
        ApiError.send(
          conn,
          :unprocessable_entity,
          "invalid_draft",
          "Draft metadata was not saved. Check the fields and your current pairing."
        )
    end
  end

  defp save_metadata(resource, actor, params) do
    with {:ok, draft} <- read_draft(resource, actor),
         {:ok, draft} <- ensure_draft(resource, draft, actor),
         {:ok, saved} <-
           draft |> Ash.Changeset.for_update(:agent_save, params, actor: actor) |> Ash.update() do
      saved
    else
      _ -> Autolaunch.Repo.rollback(:invalid_draft)
    end
  end

  def balances(conn, _params) do
    actor = credit_actor(conn)

    case RegentCredits.agent_budget(actor: actor) do
      {:ok, budget} ->
        answer = %{credits: RegentCredits.balance(actor.privy_user_id), spending_grant: budget}
        json(conn, with_note(answer, not RegentCredits.agent_grants_enabled?(), @spending_off))

      _ ->
        unavailable(conn)
    end
  end

  def history(conn, _params) do
    case conn.body_params do
      args when is_map(args) and map_size(args) == 0 ->
        history_reply(conn, %{})

      %{"after" => cursor} = args when map_size(args) == 1 and is_binary(cursor) ->
        history_reply(conn, %{after: cursor})

      _ ->
        ApiError.send(
          conn,
          :unprocessable_entity,
          "invalid_request",
          "Send an optional after cursor only."
        )
    end
  end

  def points(conn, _params) do
    case RegentPoints.summary(actor: conn.assigns.actor) do
      {:ok, summary} ->
        answer = %{
          points: Amount.format(summary.balance_micro),
          earned_today: Amount.format(summary.earned_today_micro),
          pending: summary.pending,
          daily_allowances:
            Enum.map(
              summary.allowances,
              &%{scope: &1.scope, remaining: Amount.format(&1.remaining)}
            ),
          entries:
            Enum.map(
              summary.entries,
              &%{
                points: Amount.format(&1.points_micro_delta),
                source: &1.source_app,
                by: &1.actor_kind,
                earned_at: &1.earned_at
              }
            ),
          more: summary.more?
        }

        json(conn, with_note(answer, Rules.active() == [], @points_off))

      _ ->
        unavailable(conn)
    end
  end

  defp history_reply(conn, args) do
    case RegentCredits.history(args, actor: credit_actor(conn)) do
      {:ok, page} ->
        json(conn, %{
          entries: page.entries,
          pagination: %{has_more: page.more?, next_cursor: page.next}
        })

      _ ->
        unavailable(conn)
    end
  end

  defp credit_actor(conn) do
    actor = conn.assigns.actor

    RegentCredits.Actor.agent(
      actor.privy_user_id,
      actor.wallet_address,
      "autolaunch",
      actor.pairing_id
    )
  end

  defp read_draft(resource, actor),
    do: resource |> Ash.Query.for_read(:agent_read, %{}, actor: actor) |> Ash.read_one()

  defp ensure_draft(resource, nil, actor),
    do: resource |> Ash.Changeset.for_create(:agent_create, %{}, actor: actor) |> Ash.create()

  defp ensure_draft(_resource, draft, _actor), do: {:ok, draft}
  defp resource("revstake"), do: {:ok, Autolaunch.LaunchDraft}
  defp resource("memestock"), do: {:ok, Autolaunch.Stocks.LaunchDraft}
  defp resource(_), do: {:error, :invalid_kind}
  defp present(nil), do: nil

  defp present(draft),
    do:
      Map.take(draft, [
        :id,
        :name,
        :symbol,
        :description,
        :website,
        :telegram,
        :discord,
        :other_link_1,
        :other_link_2,
        :other_link_3,
        :updated_at,
        :last_agent_pairing_id
      ])

  defp with_note(answer, true, note), do: Map.put(answer, :note, note)
  defp with_note(answer, false, _note), do: answer

  defp unavailable(conn),
    do:
      ApiError.send(
        conn,
        :service_unavailable,
        "account_unavailable",
        "Account data is unavailable; nothing was changed."
      )
end
