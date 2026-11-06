defmodule AutolaunchWeb.AgentAccountController do
  @moduledoc "Signed private reads and launch draft edits; no wallet, signing or launch authority."
  use AutolaunchWeb, :controller
  alias Autolaunch.AgentDrafts
  alias Autolaunch.Points.Board
  alias Autolaunch.SharedReading
  alias AutolaunchWeb.{ApiError, PointsEntries}
  alias RegentPoints.Rules

  @points_off "Earning Points is off on this site."

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

  def points(conn, _params) do
    actor = conn.assigns.actor

    with {:ok, summary} <- RegentPoints.summary(actor: actor),
         {:ok, %{reading: %{} = board}} <- SharedReading.fetch(Board.key()) do
      earning = Rules.active()
      answer = PointsEntries.answer(summary, board, actor.human_account_id, earning != [])
      json(conn, with_note(answer, earning == [], @points_off))
    else
      _unavailable -> unavailable(conn)
    end
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
