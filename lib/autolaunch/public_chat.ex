defmodule Autolaunch.PublicChat do
  @moduledoc false

  alias Autolaunch.Accounts.HumanUser
  alias Autolaunch.AnimataHoldings
  alias Autolaunch.EnsPrimaryName
  alias Autolaunch.Evm
  alias Autolaunch.LocalCache
  alias Autolaunch.PublicEvents
  alias Autolaunch.XMTPMirror
  alias Autolaunch.XMTPMirror.Rooms
  alias Xmtp.RoomPanel

  @room_key "public-chatbox"
  @ens_primary_name_cache_ttl_seconds 300
  @animata_holder_cache_ttl_seconds 300

  @type join_result :: {:ok, map()} | {:error, atom()}

  @spec subscribe() :: :ok
  def subscribe, do: PublicEvents.subscribe()

  @spec topic() :: String.t()
  def topic, do: PublicEvents.topic()

  @spec room_panel(HumanUser.t() | nil) :: RoomPanel.t()
  def room_panel(current_human \\ nil) do
    membership = membership_for(current_human)
    room_key = panel_room_key(membership)
    room = XMTPMirror.get_room_by_key(room_key)

    messages =
      %{"room_key" => room_key, "limit" => "50"}
      |> XMTPMirror.list_public_messages()
      |> enrich_messages()

    member_count = member_count(room_key)
    capacity = Rooms.room_capacity(room)
    panel_membership = panel_membership(current_human, membership, room, member_count, capacity)

    RoomPanel.new!(%{
      room_key: room_key,
      xmtp_group_id: room && room.xmtp_group_id,
      name: room_name(room),
      status: panel_status(room),
      membership: panel_membership,
      connected_wallet: connected_wallet(current_human),
      can_join: can_join?(current_human, room, membership, member_count, capacity),
      can_send: can_send?(current_human, membership),
      can_moderate: false,
      member_count: member_count,
      active_member_count: member_count,
      capacity: capacity,
      seats_remaining: max(capacity - member_count, 0),
      presence_ttl_seconds: room_presence_ttl(room),
      messages: messages,
      user_copy:
        RoomPanel.copy(panel_copy(current_human, room, membership, member_count, capacity))
    })
  end

  @spec request_join(HumanUser.t() | nil) :: join_result()
  def request_join(nil), do: {:error, :wallet_required}
  def request_join(%HumanUser{role: "banned"}), do: {:error, :human_banned}

  def request_join(%HumanUser{} = current_human) do
    if membership_for(current_human).state in ["joined", "join_pending", "leave_pending"] do
      {:ok, room_panel(current_human)}
    else
      case XMTPMirror.request_join(current_human, %{}) do
        {:ok, _result} -> {:ok, room_panel(current_human)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec send_message(HumanUser.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def send_message(nil, _body), do: {:error, :wallet_required}

  def send_message(%HumanUser{} = current_human, body) do
    room_key = active_room_key(current_human)

    case XMTPMirror.create_human_message(current_human, %{"room_key" => room_key, "body" => body}) do
      {:ok, _message} -> {:ok, room_panel(current_human)}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, message_error(changeset)}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @spec heartbeat(HumanUser.t() | nil) :: :ok
  def heartbeat(nil), do: :ok

  def heartbeat(%HumanUser{} = current_human) do
    _ =
      XMTPMirror.heartbeat_presence(current_human, %{"room_key" => active_room_key(current_human)})

    :ok
  end

  @spec split_messages(map()) :: %{human: list(), agent: list()}
  def split_messages(%{messages: messages}) do
    messages
    |> Enum.map(&Map.put_new(&1, :tone, "muted"))
    |> Enum.reduce(%{human: [], agent: []}, fn message, acc ->
      if Map.get(message, :sender_type) == :agent do
        %{acc | agent: [message | acc.agent]}
      else
        %{acc | human: [message | acc.human]}
      end
    end)
    |> Map.update!(:human, &Enum.reverse/1)
    |> Map.update!(:agent, &Enum.reverse/1)
  end

  def split_messages(_panel), do: %{human: [], agent: []}

  @spec reason_message(atom()) :: String.t()
  def reason_message(:wallet_required), do: "Sign in before you join this room."
  def reason_message(:room_full), do: "All seats are filled right now. You can still read along."
  def reason_message(:already_in_room), do: "Leave your current room before joining another one."
  def reason_message(:room_unavailable), do: "This room is unavailable right now."
  def reason_message(:room_not_found), do: "This room is unavailable right now."
  def reason_message(:message_required), do: "Write a message before you send it."

  def reason_message(:message_too_long),
    do: "Keep the message shorter so the room stays readable."

  def reason_message(:join_required), do: "Join the room before you post."
  def reason_message(:xmtp_membership_required), do: "Join the room before you post."
  def reason_message(:xmtp_identity_required), do: "Finish room setup before you join."
  def reason_message(:kicked), do: "This wallet was removed from the room."
  def reason_message(:human_banned), do: "This wallet cannot join this room."
  def reason_message(:join_not_allowed), do: "This wallet cannot join this room."

  def reason_message(_reason), do: "This room is unavailable right now."

  defp membership_for(%HumanUser{} = human), do: XMTPMirror.membership_for(human)

  defp membership_for(_current_human) do
    %{
      room_key: @room_key,
      room_present: not is_nil(XMTPMirror.get_room_by_key(@room_key)),
      state: "view_only"
    }
  end

  defp can_join?(nil, _room, _membership, _member_count, _capacity), do: false

  defp can_join?(%HumanUser{role: "banned"}, _room, _membership, _member_count, _capacity),
    do: false

  defp can_join?(_human, nil, _membership, _member_count, _capacity), do: false
  defp can_join?(_human, _room, %{state: "joined"}, _member_count, _capacity), do: false
  defp can_join?(_human, _room, %{state: "setup_required"}, _member_count, _capacity), do: false

  defp can_join?(_human, _room, _membership, member_count, capacity),
    do: member_count < capacity

  defp can_send?(%HumanUser{role: "banned"}, _membership), do: false
  defp can_send?(_human, %{state: "joined"}), do: true
  defp can_send?(_human, _membership), do: false

  defp member_count(room_key) do
    room_key
    |> XMTPMirror.get_room_by_key()
    |> case do
      nil -> 0
      room -> Rooms.active_member_count(room.id)
    end
  end

  defp panel_membership(%HumanUser{role: "banned"}, _membership, _room, _member_count, _capacity),
    do: :removed

  defp panel_membership(_human, _membership, nil, _member_count, _capacity), do: :not_connected
  defp panel_membership(_human, %{state: "joined"}, _room, _member_count, _capacity), do: :joined

  defp panel_membership(_human, %{state: state}, _room, _member_count, _capacity)
       when state in ["join_pending", "leave_pending"],
       do: :pending_signature

  defp panel_membership(_human, _membership, _room, member_count, capacity)
       when member_count >= capacity,
       do: :blocked

  defp panel_membership(_human, _membership, _room, _member_count, _capacity), do: :not_joined

  defp panel_status(nil), do: :disabled
  defp panel_status(%{status: "active"}), do: :ready
  defp panel_status(_room), do: :disabled

  defp room_presence_ttl(%{presence_ttl_seconds: ttl}) when is_integer(ttl) and ttl > 0,
    do: ttl

  defp room_presence_ttl(_room), do: Rooms.default_presence_ttl_seconds()

  defp panel_copy(nil, _room, _membership, _member_count, _capacity),
    do: "Read along now. Sign in before you post."

  defp panel_copy(_human, nil, _membership, _member_count, _capacity),
    do: reason_message(:room_unavailable)

  defp panel_copy(%HumanUser{role: "banned"}, _room, _membership, _member_count, _capacity),
    do: reason_message(:human_banned)

  defp panel_copy(_human, _room, %{state: "joined"}, _member_count, _capacity),
    do: "You can post in the public room."

  defp panel_copy(_human, _room, %{state: "setup_required"}, _member_count, _capacity),
    do: reason_message(:xmtp_identity_required)

  defp panel_copy(_human, _room, %{state: "join_pending"}, _member_count, _capacity),
    do: "Your room seat is being prepared."

  defp panel_copy(_human, _room, %{state: "leave_pending"}, _member_count, _capacity),
    do: "Your room seat is closing."

  defp panel_copy(_human, _room, _membership, member_count, capacity)
       when member_count >= capacity,
       do: reason_message(:room_full)

  defp panel_copy(_human, _room, _membership, _member_count, _capacity),
    do: "Sign in, then join when you want to post."

  defp message_error(%Ecto.Changeset{} = changeset) do
    cond do
      changeset_error?(changeset, :body, "can't be blank") -> :message_required
      changeset_error?(changeset, :body, "should be at least") -> :message_required
      changeset_error?(changeset, :body, "should be at most") -> :message_too_long
      true -> :room_unavailable
    end
  end

  defp changeset_error?(%Ecto.Changeset{errors: errors}, field, fragment) do
    Enum.any?(errors, fn
      {^field, {message, _opts}} -> String.contains?(message, fragment)
      _error -> false
    end)
  end

  defp room_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp room_name(_room), do: "Autolaunch Room"

  defp connected_wallet(%HumanUser{wallet_address: wallet}) when is_binary(wallet), do: wallet
  defp connected_wallet(_current_human), do: nil

  defp enrich_messages(messages) when is_list(messages) do
    profiles = sender_profiles(messages)

    Enum.map(messages, fn message ->
      sender_wallet = Evm.normalize_address(Map.get(message, :sender_wallet_address))
      profile = Map.get(profiles, sender_wallet, %{})

      message
      |> Map.put(
        :author,
        Map.get(profile, :primary_name) || Map.get(message, :sender_label) ||
          short_wallet(sender_wallet) || "Room member"
      )
      |> Map.put(:author_tone, Map.get(profile, :author_tone, :normal))
    end)
  end

  defp sender_profiles(messages) do
    messages
    |> Enum.map(&Evm.normalize_address(Map.get(&1, :sender_wallet_address)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn wallet ->
      {wallet, %{primary_name: primary_name(wallet), author_tone: author_tone(wallet)}}
    end)
  end

  defp primary_name(wallet) when is_binary(wallet) do
    case LocalCache.fetch(
           "autolaunch:xmtp-room:v1:#{wallet}:ens-primary-name",
           @ens_primary_name_cache_ttl_seconds,
           fn -> EnsPrimaryName.verified_primary_name(wallet) end
         ) do
      {:ok, name} when is_binary(name) and name != "" -> name
      _other -> nil
    end
  end

  defp author_tone(wallet) when is_binary(wallet) do
    case LocalCache.fetch(
           "autolaunch:xmtp-room:v1:#{wallet}:animata-holder",
           @animata_holder_cache_ttl_seconds,
           fn -> {:ok, AnimataHoldings.holder?(wallet)} end
         ) do
      {:ok, true} -> :animata_holder
      _other -> :normal
    end
  end

  defp short_wallet("0x" <> address) when byte_size(address) == 40,
    do: "0x#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"

  defp short_wallet(_wallet), do: nil

  defp panel_room_key(%{room_key: room_key}) when is_binary(room_key) and room_key != "",
    do: room_key

  defp panel_room_key(_membership), do: @room_key

  defp active_room_key(%HumanUser{} = human) do
    case membership_for(human) do
      %{state: "joined", room_key: room_key} when is_binary(room_key) and room_key != "" ->
        room_key

      _membership ->
        @room_key
    end
  end

  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :room_unavailable
end
