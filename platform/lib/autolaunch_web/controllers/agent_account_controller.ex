defmodule AutolaunchWeb.AgentAccountController do
  @moduledoc "Signed private reads and launch draft edits; no wallet, signing or launch authority."
  use AutolaunchWeb, :controller
  alias Autolaunch.AgentDrafts
  alias AutolaunchWeb.ApiError
  alias RegentPoints.{Amount, Rules}

  @points_off "Earning Points is off on this site."
  @spending_off "Approving agent spending is off on this site."

  plug AutolaunchWeb.Plugs.AgentAccess

  def positions(conn, params), do: AutolaunchWeb.MyPositionsController.signed(conn, params)

  def draft(conn, %{"kind" => kind}) do
    case AgentDrafts.read(kind, conn.assigns.actor) do
      {:ok, draft} -> json(conn, %{data: AgentDrafts.present(draft), kind: kind})
      _ -> unavailable(conn)
    end
  end

  # Everything the person's create form takes, from a paired agent; the
  # person still reviews and signs the launch (`Autolaunch.AgentDrafts`).
  def save_draft(conn, %{"kind" => kind}) do
    case AgentDrafts.save(kind, conn.body_params, conn.assigns.actor) do
      {:ok, draft} ->
        json(conn, %{data: AgentDrafts.present(draft), kind: kind})

      {:error, :invalid_image} ->
        ApiError.send(
          conn,
          :unprocessable_entity,
          "invalid_image",
          "Send the picture as a PNG, JPEG or WebP file, base64 in image.data with its image.content_type."
        )

      {:error, :image_too_large} ->
        ApiError.send(
          conn,
          :unprocessable_entity,
          "image_too_large",
          "The picture is larger than 2 MB, or more than 4096 by 4096 pixels."
        )

      {:error, _invalid} ->
        ApiError.send(
          conn,
          :unprocessable_entity,
          "invalid_draft",
          "The draft was not saved. Send only the draft's own fields, each as text, and check your current pairing."
        )
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

      %{"after" => _cursor} = args when map_size(args) == 1 ->
        invalid_cursor(conn)

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

      {:error, error} ->
        if cursor_error?(error), do: invalid_cursor(conn), else: unavailable(conn)
    end
  end

  defp cursor_error?(%Ash.Error.Action.InvalidArgument{field: :after}), do: true
  defp cursor_error?(%Ash.Error.Page.InvalidKeyset{}), do: true

  defp cursor_error?(%Ash.Error.Invalid{errors: [_ | _] = errors}),
    do: Enum.all?(errors, &cursor_error?/1)

  defp cursor_error?(_error), do: false

  defp invalid_cursor(conn),
    do:
      ApiError.send(
        conn,
        :unprocessable_entity,
        "invalid_cursor",
        "That history cursor is invalid."
      )

  defp credit_actor(conn) do
    actor = conn.assigns.actor

    RegentCredits.Actor.agent(
      actor.privy_user_id,
      actor.wallet_address,
      "autolaunch",
      actor.pairing_id
    )
  end

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
