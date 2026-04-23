defmodule Autolaunch.XMTPMirror do
  @moduledoc false

  import Ecto.Query

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.Repo
  alias Autolaunch.XmtpIdentity

  alias Autolaunch.XMTPMirror.{
    XmtpMembershipCommand,
    XmtpMessage,
    XmtpPresence,
    XmtpRoom
  }

  @canonical_room_key "public-chatbox"
  @default_limit 50
  @default_capacity 200
  @default_presence_ttl_seconds 120

  @type room_admin_action_error ::
          :human_not_found | :human_banned | :room_not_found | :xmtp_identity_required

  @type room_admin_action_status ::
          :enqueued
          | :already_joined
          | :already_pending_join
          | :already_not_joined
          | :already_pending_removal

  @spec ensure_room(map()) :: {:ok, XmtpRoom.t()} | {:error, Ecto.Changeset.t()}
  def ensure_room(attrs) when is_map(attrs) do
    key = value_for(attrs, :room_key)

    case get_room_by_key(key) do
      nil ->
        %XmtpRoom{}
        |> XmtpRoom.changeset(normalize_room_attrs(attrs))
        |> Repo.insert()

      %XmtpRoom{} = room ->
        room
        |> XmtpRoom.changeset(normalize_room_attrs(attrs))
        |> Repo.update()
    end
  end

  @spec get_room_by_key(String.t() | nil) :: XmtpRoom.t() | nil
  def get_room_by_key(room_key) when is_binary(room_key) and room_key != "" do
    Repo.get_by(XmtpRoom, room_key: room_key)
  end

  def get_room_by_key(_room_key), do: nil

  @spec ingest_message(map()) ::
          {:ok, XmtpMessage.t()}
          | {:error,
             :room_not_found
             | :invalid_reply_to_message
             | :invalid_reactions
             | :invalid_sent_at
             | Ecto.Changeset.t()}
  def ingest_message(attrs) when is_map(attrs) do
    with {:ok, room} <- resolve_message_room(attrs),
         :ok <- validate_reaction_payload(attrs),
         :ok <- validate_reply_to_message(attrs),
         {:ok, sent_at} <- parse_sent_at(value_for(attrs, :sent_at)) do
      message_attrs =
        attrs
        |> normalize_message_attrs(room)
        |> Map.put(:sent_at, sent_at)
        |> Map.put(:room_id, room.id)

      %XmtpMessage{}
      |> XmtpMessage.changeset(message_attrs)
      |> Repo.insert()
      |> case do
        {:ok, %XmtpMessage{} = message} ->
          {:ok, message}

        {:error, %Ecto.Changeset{errors: [xmtp_message_id: {"has already been taken", _}]}} ->
          case Repo.get_by(XmtpMessage, xmtp_message_id: message_attrs.xmtp_message_id) do
            %XmtpMessage{} = message -> {:ok, message}
            nil -> {:error, :room_not_found}
          end

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @spec lease_next_command(String.t() | integer() | nil) :: XmtpMembershipCommand.t() | nil
  def lease_next_command(room_key_or_id) do
    case resolve_room(room_key_or_id) do
      nil ->
        nil

      %XmtpRoom{id: room_id} ->
        Repo.transaction(fn ->
          case pending_command_query(room_id) |> Repo.one() do
            nil ->
              nil

            %XmtpMembershipCommand{} = command ->
              command
              |> Ecto.Changeset.change(
                status: "processing",
                attempt_count: command.attempt_count + 1
              )
              |> Repo.update!()
          end
        end)
        |> case do
          {:ok, nil} -> nil
          {:ok, %XmtpMembershipCommand{} = command} -> command
          {:error, _reason} -> nil
        end
    end
  end

  @spec resolve_command(integer() | String.t(), map()) ::
          :ok | {:error, :command_not_found | :invalid_command_id | :invalid_resolution_status}
  def resolve_command(command_id, attrs) do
    with {:ok, normalized_id} <- parse_positive_id(command_id),
         %XmtpMembershipCommand{} = command <-
           Repo.get(XmtpMembershipCommand, normalized_id) do
      status = normalize_status(value_for(attrs, :status))

      case status do
        "done" ->
          command
          |> Ecto.Changeset.change(status: "done", last_error: nil)
          |> Repo.update!()

          :ok

        "failed" ->
          command
          |> Ecto.Changeset.change(
            status: "failed",
            last_error: normalize_error_message(value_for(attrs, :error))
          )
          |> Repo.update!()

          :ok

        _ ->
          {:error, :invalid_resolution_status}
      end
    else
      {:error, :invalid_command_id} -> {:error, :invalid_command_id}
      nil -> {:error, :command_not_found}
    end
  end

  @spec request_join(HumanUser.t(), map()) ::
          {:ok, map()} | {:error, :room_not_found | :human_banned | :xmtp_identity_required}
  def request_join(human, attrs \\ %{})

  def request_join(%HumanUser{role: "banned"}, _attrs), do: {:error, :human_banned}

  def request_join(%HumanUser{} = human, attrs) when is_map(attrs) do
    with {:ok, inbox_id} <- require_human_inbox_id(human),
         {:ok, room} <- resolve_join_room(attrs) do
      status = membership_state_for(human, room)

      case status do
        "joined" ->
          {:ok, %{status: "joined", human_id: human.id, room_key: room.room_key}}

        "join_pending" ->
          {:ok, %{status: "pending", human_id: human.id, room_key: room.room_key}}

        "leave_pending" ->
          {:ok, %{status: "pending", human_id: human.id, room_key: room.room_key}}

        _ ->
          case create_membership_command(human, room, inbox_id, "add_member") do
            {:ok, _command} ->
              {:ok,
               %{
                 status: "pending",
                 human_id: human.id,
                 room_key: room.room_key,
                 shard_key: room.room_key
               }}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @spec create_human_message(HumanUser.t(), map()) ::
          {:ok, XmtpMessage.t()}
          | {:error,
             :human_banned
             | :room_not_found
             | :xmtp_identity_required
             | :invalid_sent_at
             | Ecto.Changeset.t()}
  def create_human_message(%HumanUser{role: "banned"}, _attrs), do: {:error, :human_banned}

  def create_human_message(%HumanUser{} = human, attrs) when is_map(attrs) do
    with {:ok, inbox_id} <- require_human_inbox_id(human),
         {:ok, room} <- resolve_message_room(attrs),
         {:ok, sent_at} <- parse_sent_at(value_for(attrs, :sent_at)) do
      message_id =
        value_for(attrs, :xmtp_message_id) ||
          "xmtp-#{room.id}-#{human.id}-#{System.unique_integer([:positive, :monotonic])}"

      message_attrs = %{
        room_id: room.id,
        xmtp_message_id: message_id,
        sender_inbox_id: inbox_id,
        sender_wallet_address: human.wallet_address,
        sender_label: human.display_name,
        sender_type: :human,
        body: value_for(attrs, :body) || "",
        sent_at: sent_at,
        raw_payload: value_for(attrs, :raw_payload) || %{},
        moderation_state: value_for(attrs, :moderation_state) || "visible",
        reply_to_message_id: value_for(attrs, :reply_to_message_id),
        reactions: value_for(attrs, :reactions) || %{}
      }

      %XmtpMessage{}
      |> XmtpMessage.changeset(message_attrs)
      |> Repo.insert()
    end
  end

  @spec list_public_messages(map()) :: [XmtpMessage.t()]
  def list_public_messages(attrs \\ %{}) when is_map(attrs) do
    room =
      case resolve_message_room(attrs) do
        {:ok, room} -> room
        {:error, _} -> nil
      end

    if room do
      XmtpMessage
      |> where([m], m.room_id == ^room.id and m.moderation_state == "visible")
      |> order_by([m], desc: m.sent_at, desc: m.id)
      |> limit(^parse_limit(attrs, @default_limit))
      |> Repo.all()
    else
      []
    end
  end

  @spec heartbeat_presence(HumanUser.t(), map()) ::
          {:ok, map()}
          | {:error,
             :room_not_found | :human_banned | :xmtp_identity_required | Ecto.Changeset.t()}
  def heartbeat_presence(human, attrs \\ %{})

  def heartbeat_presence(%HumanUser{role: "banned"}, _attrs), do: {:error, :human_banned}

  def heartbeat_presence(%HumanUser{} = human, attrs) when is_map(attrs) do
    with {:ok, inbox_id} <- require_human_inbox_id(human),
         {:ok, room} <- resolve_join_room(attrs) do
      now = DateTime.utc_now()

      expires_at =
        DateTime.add(now, room.presence_ttl_seconds || @default_presence_ttl_seconds, :second)

      presence_attrs = %{
        room_id: room.id,
        human_user_id: human.id,
        xmtp_inbox_id: inbox_id,
        last_seen_at: now,
        expires_at: expires_at,
        evicted_at: nil
      }

      presence =
        case Repo.get_by(XmtpPresence,
               room_id: room.id,
               xmtp_inbox_id: presence_attrs.xmtp_inbox_id
             ) do
          nil ->
            %XmtpPresence{}
            |> XmtpPresence.changeset(presence_attrs)
            |> Repo.insert!()

          %XmtpPresence{} = existing ->
            existing
            |> XmtpPresence.changeset(presence_attrs)
            |> Repo.update!()
        end

      eviction_count = enqueue_expired_presence_evictions(room, now)

      {:ok,
       %{
         status: "alive",
         room_key: room.room_key,
         eviction_enqueued: eviction_count,
         presence_id: presence.id
       }}
    end
  end

  @spec membership_for(HumanUser.t()) :: map()
  def membership_for(%HumanUser{} = human) do
    room_key = @canonical_room_key

    case get_room_by_key(room_key) do
      nil ->
        %{
          human_id: human.id,
          room_key: room_key,
          room_present: false,
          state: "room_unavailable"
        }

      %XmtpRoom{} = room ->
        case require_human_inbox_id(human) do
          {:ok, _inbox_id} ->
            %{
              human_id: human.id,
              room_key: room.room_key,
              room_present: true,
              state: membership_state_for(human, room)
            }

          {:error, :xmtp_identity_required} ->
            %{
              human_id: human.id,
              room_key: room.room_key,
              room_present: true,
              state: "setup_required"
            }
        end
    end
  end

  @spec add_human_to_canonical_room(integer() | String.t()) ::
          {:ok, room_admin_action_status()} | {:error, room_admin_action_error()}
  def add_human_to_canonical_room(human_id) when is_integer(human_id) or is_binary(human_id) do
    with {:ok, human} <- fetch_human(human_id),
         {:ok, room} <- resolve_join_room(%{}) do
      case membership_state_for(human, room) do
        "joined" ->
          {:ok, :already_joined}

        "join_pending" ->
          {:ok, :already_pending_join}

        _ ->
          case request_join(human, %{}) do
            {:ok, _result} -> {:ok, :enqueued}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, :room_not_found} -> {:error, :room_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remove_human_from_canonical_room(integer() | String.t() | HumanUser.t()) ::
          {:ok, room_admin_action_status()} | {:error, room_admin_action_error()}
  def remove_human_from_canonical_room(%HumanUser{} = human) do
    case resolve_join_room(%{}) do
      {:ok, room} ->
        case membership_state_for(human, room) do
          "not_joined" ->
            {:ok, :already_not_joined}

          "join_failed" ->
            {:ok, :already_not_joined}

          "leave_pending" ->
            {:ok, :already_pending_removal}

          _ ->
            case require_human_inbox_id(human) do
              {:ok, inbox_id} ->
                case create_membership_command(human, room, inbox_id, "remove_member") do
                  {:ok, _command} -> {:ok, :enqueued}
                  {:error, reason} -> {:error, reason}
                end

              {:error, :xmtp_identity_required} ->
                {:error, :xmtp_identity_required}
            end
        end

      {:error, _} ->
        {:error, :room_not_found}
    end
  end

  def remove_human_from_canonical_room(human_id)
      when is_integer(human_id) or is_binary(human_id) do
    with {:ok, human} <- fetch_human(human_id) do
      remove_human_from_canonical_room(human)
    end
  end

  @spec best_effort_remove_human_from_canonical_room(integer() | String.t()) :: :ok
  def best_effort_remove_human_from_canonical_room(human_id)
      when is_integer(human_id) or is_binary(human_id) do
    case remove_human_from_canonical_room(human_id) do
      {:ok, _status} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec list_shards() :: [map()]
  def list_shards do
    XmtpRoom
    |> where([r], r.status == "active")
    |> order_by([r], asc: r.room_key)
    |> Repo.all()
    |> Enum.map(&encode_shard/1)
  end

  defp encode_shard(%XmtpRoom{} = room) do
    active_members = active_member_count(room.id)

    %{
      id: room.id,
      room_key: room.room_key,
      xmtp_group_id: room.xmtp_group_id,
      name: room.name,
      status: room.status,
      presence_ttl_seconds: room.presence_ttl_seconds,
      capacity: @default_capacity,
      active_members: active_members,
      joinable: active_members < @default_capacity
    }
  end

  defp active_member_count(room_id) do
    add_count =
      XmtpMembershipCommand
      |> where([c], c.room_id == ^room_id and c.op == "add_member" and c.status == "done")
      |> Repo.aggregate(:count, :id)

    remove_count =
      XmtpMembershipCommand
      |> where([c], c.room_id == ^room_id and c.op == "remove_member" and c.status == "done")
      |> Repo.aggregate(:count, :id)

    max(add_count - remove_count, 0)
  end

  defp pending_command_query(room_id) do
    XmtpMembershipCommand
    |> where([c], c.room_id == ^room_id and c.status == "pending")
    |> order_by([c], asc: c.inserted_at, asc: c.id)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> limit(1)
  end

  defp create_membership_command(%HumanUser{} = human, %XmtpRoom{} = room, inbox_id, op) do
    existing =
      XmtpMembershipCommand
      |> where(
        [c],
        c.room_id == ^room.id and c.human_user_id == ^human.id and c.op == ^op and
          c.status in ["pending", "processing"]
      )
      |> limit(1)
      |> Repo.one()

    if existing do
      {:ok, existing}
    else
      %XmtpMembershipCommand{}
      |> XmtpMembershipCommand.enqueue_changeset(%{
        room_id: room.id,
        human_user_id: human.id,
        op: op,
        xmtp_inbox_id: inbox_id,
        status: "pending"
      })
      |> Repo.insert()
    end
  end

  defp enqueue_expired_presence_evictions(%XmtpRoom{} = room, now) do
    expired_presences =
      XmtpPresence
      |> where([p], p.room_id == ^room.id and is_nil(p.evicted_at) and p.expires_at <= ^now)
      |> Repo.all()

    Enum.reduce(expired_presences, 0, fn presence, count ->
      case presence.evicted_at do
        nil ->
          _ = create_eviction_command(presence, room)

          _ =
            presence
            |> Ecto.Changeset.change(evicted_at: now)
            |> Repo.update!()

          count + 1

        _ ->
          count
      end
    end)
  end

  defp create_eviction_command(%XmtpPresence{} = presence, %XmtpRoom{} = room) do
    existing =
      XmtpMembershipCommand
      |> where(
        [c],
        c.room_id == ^room.id and c.human_user_id == ^presence.human_user_id and
          c.xmtp_inbox_id == ^presence.xmtp_inbox_id and c.op == "remove_member" and
          c.status in ["pending", "processing"]
      )
      |> limit(1)
      |> Repo.one()

    if existing do
      existing
    else
      %XmtpMembershipCommand{}
      |> XmtpMembershipCommand.enqueue_changeset(%{
        room_id: room.id,
        human_user_id: presence.human_user_id,
        op: "remove_member",
        xmtp_inbox_id: presence.xmtp_inbox_id,
        status: "pending"
      })
      |> Repo.insert!()
    end
  end

  defp membership_state_for(%HumanUser{} = human, %XmtpRoom{} = room) do
    latest =
      XmtpMembershipCommand
      |> where([c], c.room_id == ^room.id and c.human_user_id == ^human.id)
      |> order_by([c], desc: c.inserted_at, desc: c.id)
      |> limit(1)
      |> Repo.one()

    case latest do
      nil -> "not_joined"
      %XmtpMembershipCommand{op: "add_member", status: "pending"} -> "join_pending"
      %XmtpMembershipCommand{op: "add_member", status: "processing"} -> "join_pending"
      %XmtpMembershipCommand{op: "add_member", status: "done"} -> "joined"
      %XmtpMembershipCommand{op: "add_member", status: "failed"} -> "join_failed"
      %XmtpMembershipCommand{op: "remove_member", status: "pending"} -> "leave_pending"
      %XmtpMembershipCommand{op: "remove_member", status: "processing"} -> "leave_pending"
      %XmtpMembershipCommand{op: "remove_member", status: "done"} -> "not_joined"
      %XmtpMembershipCommand{op: "remove_member", status: "failed"} -> "leave_failed"
      _ -> "not_joined"
    end
  end

  defp require_human_inbox_id(%HumanUser{} = human) do
    case XmtpIdentity.ready_inbox_id(human) do
      {:ok, inbox_id} -> {:ok, inbox_id}
      {:error, :wallet_address_required} -> {:error, :xmtp_identity_required}
      {:error, :xmtp_identity_required} -> {:error, :xmtp_identity_required}
    end
  end

  defp fetch_human(human_id) do
    case Repo.get(HumanUser, normalize_id(human_id)) do
      %HumanUser{} = human -> {:ok, human}
      nil -> {:error, :human_not_found}
    end
  end

  defp resolve_join_room(attrs) do
    room =
      case explicit_room_reference?(attrs) do
        true -> resolve_room(attrs)
        false -> select_join_room()
      end

    case room do
      nil -> {:error, :room_not_found}
      %XmtpRoom{} = resolved -> {:ok, resolved}
    end
  end

  defp resolve_message_room(attrs) do
    case resolve_room(attrs) do
      nil -> {:error, :room_not_found}
      room -> {:ok, room}
    end
  end

  defp resolve_room(%{} = attrs) do
    cond do
      room_id = value_for(attrs, :room_id) ->
        Repo.get(XmtpRoom, normalize_id(room_id))

      shard_key = value_for(attrs, :shard_key) ->
        get_room_by_key(shard_key)

      room_key = value_for(attrs, :room_key) ->
        get_room_by_key(room_key)

      true ->
        get_room_by_key(@canonical_room_key)
    end
  end

  defp resolve_room(room_key) when is_binary(room_key), do: get_room_by_key(room_key)
  defp resolve_room(room_id) when is_integer(room_id), do: Repo.get(XmtpRoom, room_id)
  defp resolve_room(_), do: nil

  defp explicit_room_reference?(attrs) when is_map(attrs) do
    not is_nil(value_for(attrs, :room_id)) or
      not is_nil(value_for(attrs, :shard_key)) or
      not is_nil(value_for(attrs, :room_key))
  end

  defp explicit_room_reference?(_attrs), do: false

  defp select_join_room do
    case list_joinable_rooms() do
      [room | _rest] -> room
      [] -> ensure_next_shard_room()
    end
  end

  defp list_joinable_rooms do
    XmtpRoom
    |> where([r], r.status == "active" and like(r.room_key, ^"#{@canonical_room_key}%"))
    |> Repo.all()
    |> Enum.sort_by(&room_sort_key/1)
    |> Enum.filter(&(active_member_count(&1.id) < @default_capacity))
  end

  defp room_sort_key(%XmtpRoom{room_key: @canonical_room_key}), do: 1

  defp room_sort_key(%XmtpRoom{room_key: room_key}) do
    room_key
    |> String.replace_prefix("#{@canonical_room_key}-shard-", "")
    |> Integer.parse()
    |> case do
      {shard_number, ""} when shard_number > 0 -> shard_number
      _ -> 9_999
    end
  end

  defp ensure_next_shard_room do
    canonical_room = get_room_by_key(@canonical_room_key)

    if canonical_room do
      next_number =
        XmtpRoom
        |> where([r], like(r.room_key, ^"#{@canonical_room_key}-shard-%"))
        |> Repo.all()
        |> Enum.map(&room_sort_key/1)
        |> Enum.reject(&(&1 == 9_999))
        |> Enum.max(fn -> 1 end)
        |> Kernel.+(1)

      shard_key = "#{@canonical_room_key}-shard-#{next_number}"

      case ensure_room(%{
             room_key: shard_key,
             xmtp_group_id: "xmtp-#{shard_key}",
             name: "#{canonical_room.name || "Public Chatbox"} ##{next_number}",
             status: canonical_room.status || "active",
             presence_ttl_seconds:
               canonical_room.presence_ttl_seconds || @default_presence_ttl_seconds
           }) do
        {:ok, room} -> room
        {:error, _changeset} -> get_room_by_key(shard_key)
      end
    end
  end

  defp normalize_room_attrs(attrs) do
    %{
      room_key: value_for(attrs, :room_key),
      xmtp_group_id: value_for(attrs, :xmtp_group_id),
      name: value_for(attrs, :name),
      status: value_for(attrs, :status) || "active",
      presence_ttl_seconds:
        value_for(attrs, :presence_ttl_seconds) || @default_presence_ttl_seconds
    }
  end

  defp normalize_message_attrs(attrs, room) do
    %{
      room_id: room.id,
      xmtp_message_id: value_for(attrs, :xmtp_message_id),
      sender_inbox_id: value_for(attrs, :sender_inbox_id),
      sender_wallet_address: value_for(attrs, :sender_wallet_address),
      sender_label: value_for(attrs, :sender_label),
      sender_type: value_for(attrs, :sender_type) || :human,
      body: value_for(attrs, :body),
      sent_at: value_for(attrs, :sent_at),
      raw_payload: value_for(attrs, :raw_payload) || %{},
      moderation_state: value_for(attrs, :moderation_state) || "visible",
      reply_to_message_id: value_for(attrs, :reply_to_message_id),
      reactions: value_for(attrs, :reactions) || %{}
    }
  end

  defp validate_reply_to_message(attrs) do
    case value_for(attrs, :reply_to_message_id) do
      nil ->
        :ok

      reply_to_id when is_integer(reply_to_id) ->
        if Repo.get(XmtpMessage, reply_to_id), do: :ok, else: {:error, :invalid_reply_to_message}

      reply_to_id when is_binary(reply_to_id) ->
        case Integer.parse(String.trim(reply_to_id)) do
          {id, ""} when id > 0 ->
            if Repo.get(XmtpMessage, id), do: :ok, else: {:error, :invalid_reply_to_message}

          _ ->
            {:error, :invalid_reply_to_message}
        end

      _ ->
        {:error, :invalid_reply_to_message}
    end
  end

  defp validate_reaction_payload(attrs) do
    case value_for(attrs, :reactions) do
      nil -> :ok
      reactions when is_map(reactions) -> :ok
      _ -> {:error, :invalid_reactions}
    end
  end

  defp parse_sent_at(%DateTime{} = dt), do: {:ok, dt}

  defp parse_sent_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_sent_at}
    end
  end

  defp parse_sent_at(_value), do: {:error, :invalid_sent_at}

  defp normalize_status(status) when is_binary(status), do: String.trim(status)
  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(_status), do: ""

  defp normalize_error_message(nil), do: "membership_command_failed"

  defp normalize_error_message(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "membership_command_failed"
      trimmed -> trimmed
    end
  end

  defp normalize_error_message(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_error_message(_value), do: "membership_command_failed"

  defp parse_limit(attrs, default) do
    case value_for(attrs, :limit) do
      nil ->
        default

      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp normalize_id(value) when is_integer(value), do: value

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> id
      _ -> raise Ecto.NoResultsError
    end
  end

  defp normalize_id(_value), do: raise(Ecto.NoResultsError)

  defp parse_positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_command_id}
    end
  end

  defp parse_positive_id(_value), do: {:error, :invalid_command_id}

  defp value_for(attrs, key) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp value_for(_attrs, _key), do: nil
end
