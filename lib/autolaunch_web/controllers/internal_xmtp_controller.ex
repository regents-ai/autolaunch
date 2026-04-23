defmodule AutolaunchWeb.InternalXmtpController do
  use AutolaunchWeb, :controller

  alias Autolaunch.XMTPMirror
  alias Autolaunch.XMTPMirror.XmtpRoom
  alias AutolaunchWeb.ApiError

  @spec list_shards(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def list_shards(conn, _params) do
    json(conn, %{data: XMTPMirror.list_shards()})
  end

  @spec ensure_room(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ensure_room(conn, params) do
    room_attrs =
      %{
        room_key: params["room_key"],
        xmtp_group_id: params["xmtp_group_id"],
        name: params["name"],
        status: params["status"] || "active",
        presence_ttl_seconds: params["presence_ttl_seconds"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case XMTPMirror.ensure_room(room_attrs) do
      {:ok, room} ->
        json(conn, %{data: encode_room(room)})

      {:error, %Ecto.Changeset{} = changeset} ->
        render_changeset_error(conn, "room_ensure_failed", changeset)
    end
  end

  @spec ingest_message(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ingest_message(conn, params) do
    with {:ok, room} <- fetch_room(params["room_key"]),
         {:ok, message} <-
           XMTPMirror.ingest_message(%{
             room_id: room.id,
             xmtp_message_id: params["xmtp_message_id"],
             sender_inbox_id: params["sender_inbox_id"],
             sender_wallet_address: params["sender_wallet_address"],
             sender_label: params["sender_label"],
             sender_type: params["sender_type"],
             body: params["body"],
             sent_at: params["sent_at"],
             raw_payload: params["raw_payload"] || %{},
             moderation_state: params["moderation_state"] || "visible",
             reply_to_message_id: params["reply_to_message_id"],
             reactions: params["reactions"]
           }) do
      json(conn, %{data: %{id: message.id}})
    else
      {:error, :room_not_found} ->
        ApiError.render(conn, :unprocessable_entity, "room_not_found", "Requested room not found")

      {:error, :invalid_reply_to_message} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_reply_to_message",
          "Reply target not found"
        )

      {:error, :invalid_reactions} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_reactions",
          "Reactions payload is invalid"
        )

      {:error, :invalid_sent_at} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_sent_at",
          "Message timestamp is invalid"
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        render_changeset_error(conn, "message_ingest_failed", changeset)
    end
  end

  @spec lease_command(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def lease_command(conn, %{"room_key" => room_key}) do
    json(conn, %{
      data:
        case XMTPMirror.lease_next_command(room_key) do
          nil ->
            nil

          command ->
            %{
              id: command.id,
              op: command.op,
              xmtp_inbox_id: command.xmtp_inbox_id
            }
        end
    })
  end

  def lease_command(conn, _params) do
    ApiError.render(conn, :unprocessable_entity, "room_key_required", "room_key is required")
  end

  @spec resolve_command(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def resolve_command(conn, %{"id" => id} = params) do
    case parse_positive_int(id) do
      {:ok, normalized_id} ->
        render_command_resolution(
          conn,
          XMTPMirror.resolve_command(normalized_id, %{
            status: params["status"],
            error: params["error"]
          })
        )

      {:error, _reason} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_command_id",
          "Command id is invalid"
        )
    end
  end

  defp fetch_room(room_key) when is_binary(room_key) do
    case XMTPMirror.get_room_by_key(room_key) do
      nil -> {:error, :room_not_found}
      room -> {:ok, room}
    end
  end

  defp fetch_room(_room_key), do: {:error, :room_not_found}

  defp encode_room(%XmtpRoom{} = room) do
    %{
      id: room.id,
      room_key: room.room_key,
      xmtp_group_id: room.xmtp_group_id,
      name: room.name,
      status: room.status,
      presence_ttl_seconds: room.presence_ttl_seconds
    }
  end

  defp render_changeset_error(conn, code, changeset) do
    ApiError.render(conn, :unprocessable_entity, code, "Request could not be saved", %{
      details: translate_changeset(changeset)
    })
  end

  defp render_command_resolution(conn, result) do
    case result do
      :ok ->
        json(conn, %{ok: true})

      {:error, :command_not_found} ->
        ApiError.render(conn, :not_found, "command_not_found", "Command not found")

      {:error, :invalid_command_id} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "invalid_command_id",
          "Command id is invalid"
        )

      {:error, :invalid_resolution_status} ->
        ApiError.render(
          conn,
          :unprocessable_entity,
          "command_resolution_status_invalid",
          "Command resolution status is invalid"
        )
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_positive_int(_value), do: {:error, :invalid_integer}

  defp translate_changeset(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
