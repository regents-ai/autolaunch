defmodule Autolaunch.PublicChatTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.PublicChat
  alias Autolaunch.PublicEvents
  alias Autolaunch.XMTPMirror
  alias Autolaunch.XMTPMirror.XmtpMembershipCommand
  alias Autolaunch.XMTPMirror.XmtpPresence
  alias Xmtp.RoomPanel

  import Autolaunch.TestSupport.XmtpSupport, only: [deterministic_inbox_id: 1, unique_suffix: 0]

  setup do
    previous_animata = Application.get_env(:autolaunch, :animata_holdings)
    previous_ens = Application.get_env(:autolaunch, :ens_primary_name)

    Application.put_env(:autolaunch, :animata_holdings,
      http_client: __MODULE__.AnimataHttp,
      opensea_api_key: "test-key"
    )

    Application.put_env(:autolaunch, :ens_primary_name,
      rpc_module: __MODULE__.EnsPrimaryRpc,
      rpc_url: "https://ethereum.example.invalid"
    )

    {:ok, room} =
      XMTPMirror.ensure_room(%{
        "room_key" => "public-chatbox",
        "xmtp_group_id" => "xmtp-public-chatbox-#{unique_suffix()}",
        "name" => "Autolaunch Room",
        "status" => "active",
        "presence_ttl_seconds" => 120
      })

    on_exit(fn ->
      restore_app_env(:autolaunch, :animata_holdings, previous_animata)
      restore_app_env(:autolaunch, :ens_primary_name, previous_ens)
    end)

    {:ok, room: room}
  end

  test "signed-out visitors can read mirrored public messages", %{room: room} do
    assert {:ok, _message} =
             XMTPMirror.ingest_message(%{
               "room_id" => room.id,
               "xmtp_message_id" => "agent-message-#{unique_suffix()}",
               "sender_inbox_id" => "agent-inbox",
               "sender_label" => "Autolaunch agent",
               "sender_type" => "agent",
               "body" => "The room is open for launch updates.",
               "sent_at" => DateTime.utc_now()
             })

    panel = PublicChat.room_panel(nil)

    assert %RoomPanel{} = panel
    assert panel.room_key == "public-chatbox"
    assert panel.name == "Autolaunch Room"
    assert panel.status == :ready
    assert panel.can_join == false
    assert panel.can_send == false
    assert [%{body: "The room is open for launch updates.", sender_type: :agent}] = panel.messages
  end

  test "room messages show verified ENS names and mark Animata holders", %{room: room} do
    wallet = "0xabc0000000000000000000000000000000000011"

    assert {:ok, _message} =
             XMTPMirror.ingest_message(%{
               "room_id" => room.id,
               "xmtp_message_id" => "ens-message-#{unique_suffix()}",
               "sender_inbox_id" => deterministic_inbox_id(wallet),
               "sender_wallet_address" => wallet,
               "sender_label" => "Stored label",
               "sender_type" => "human",
               "body" => "Name check.",
               "sent_at" => DateTime.utc_now()
             })

    panel = PublicChat.room_panel(nil)

    assert [%{author: "primary-room.eth", author_tone: :animata_holder}] = panel.messages
  end

  test "joining queues a mirror membership command", %{room: room} do
    assert {:error, :wallet_required} = PublicChat.request_join(nil)

    assert {:error, :xmtp_identity_required} =
             PublicChat.request_join(create_human!("No Identity", xmtp_identity?: false))

    human = create_human!("Pending")

    assert {:ok, panel} = PublicChat.request_join(human)
    assert panel.membership == :pending_signature
    assert panel.can_send == false

    command = Repo.get_by!(XmtpMembershipCommand, room_id: room.id, human_user_id: human.id)
    assert command.op == "add_member"
    assert command.status == "pending"
    assert command.xmtp_inbox_id == human.xmtp_inbox_id
  end

  test "completed join commands refresh the public room", %{room: room} do
    human = create_human!("Refresh")

    assert {:ok, _panel} = PublicChat.request_join(human)
    command = Repo.get_by!(XmtpMembershipCommand, room_id: room.id, human_user_id: human.id)

    :ok = PublicEvents.subscribe()

    assert :ok = XMTPMirror.resolve_command(command.id, %{"status" => "done"})

    assert_receive {:public_site_event,
                    %{
                      event: :xmtp_room_membership,
                      room_key: "public-chatbox"
                    }}

    assert PublicChat.room_panel(human).membership == :joined
  end

  test "one human cannot join two public rooms at the same time", %{room: room} do
    human = create_human!("One Room")
    join_human!(human, room)

    {:ok, auction_room} =
      XMTPMirror.ensure_room(%{
        "room_key" => "auction:#{unique_suffix()}",
        "xmtp_group_id" => "xmtp-auction-#{unique_suffix()}",
        "name" => "Auction Room",
        "status" => "active"
      })

    assert {:error, :already_in_room} =
             XMTPMirror.request_join(human, %{"room_key" => auction_room.room_key})
  end

  test "only joined mirror members can post", %{room: room} do
    assert {:error, :wallet_required} = PublicChat.send_message(nil, "hello")

    assert {:error, :xmtp_identity_required} =
             PublicChat.send_message(create_human!("No Identity", xmtp_identity?: false), "hello")

    assert {:error, :xmtp_membership_required} =
             PublicChat.send_message(create_human!("Not Joined"), "hello")

    human = create_human!("Joined")
    join_human!(human, room)

    assert {:error, :message_required} = PublicChat.send_message(human, "   ")

    assert {:error, :message_too_long} =
             PublicChat.send_message(human, String.duplicate("a", 10_001))

    :ok = PublicEvents.subscribe()

    assert {:ok, panel} = PublicChat.send_message(human, "hello from the homepage")
    assert panel.membership == :joined
    assert panel.can_send == true
    assert [%{body: "hello from the homepage", sender_type: :human}] = panel.messages

    assert_receive {:public_site_event,
                    %{
                      event: :xmtp_room_message,
                      room_key: "public-chatbox",
                      message: %{body: "hello from the homepage"}
                    }}
  end

  test "banned human messages stay out of public reads", %{room: room} do
    banned = create_human!("Banned", role: "banned")

    assert {:ok, _message} =
             XMTPMirror.ingest_message(%{
               "room_id" => room.id,
               "xmtp_message_id" => "banned-message-#{unique_suffix()}",
               "sender_inbox_id" => banned.xmtp_inbox_id,
               "sender_wallet_address" => banned.wallet_address,
               "sender_label" => banned.display_name,
               "sender_type" => "human",
               "body" => "do not relay",
               "sent_at" => DateTime.utc_now()
             })

    assert PublicChat.room_panel(nil).messages == []
  end

  test "banned humans cannot use public room actions", %{room: room} do
    banned = create_human!("Banned Actions", role: "banned")
    join_human!(banned, room)

    panel = PublicChat.room_panel(banned)

    assert panel.membership == :removed
    assert panel.can_join == false
    assert panel.can_send == false
    assert panel.user_copy.primary == "This wallet cannot join this room."
    assert {:error, :human_banned} = PublicChat.request_join(banned)
    assert {:error, :human_banned} = PublicChat.send_message(banned, "hello")
  end

  test "heartbeat records presence through the mirror room", %{room: room} do
    assert :ok = PublicChat.heartbeat(nil)
    assert :ok = PublicChat.heartbeat(create_human!("No Identity", xmtp_identity?: false))

    human = create_human!("Alive")

    assert :ok = PublicChat.heartbeat(human)

    presence = Repo.get_by!(XmtpPresence, room_id: room.id, human_user_id: human.id)
    assert presence.xmtp_inbox_id == human.xmtp_inbox_id
    assert DateTime.compare(presence.expires_at, presence.last_seen_at) == :gt
  end

  defp create_human!(label, opts \\ []) do
    wallet = "0x#{String.pad_leading(Integer.to_string(unique_suffix(), 16), 40, "0")}"
    xmtp_identity? = Keyword.get(opts, :xmtp_identity?, true)
    role = Keyword.get(opts, :role, "user")

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("privy-public-chat-#{label}-#{unique_suffix()}", %{
        "wallet_address" => wallet,
        "wallet_addresses" => [wallet],
        "xmtp_inbox_id" => if(xmtp_identity?, do: deterministic_inbox_id(wallet)),
        "display_name" => label,
        "role" => role
      })

    human
  end

  defp join_human!(human, room) do
    %XmtpMembershipCommand{}
    |> XmtpMembershipCommand.enqueue_changeset(%{
      "room_id" => room.id,
      "human_user_id" => human.id,
      "op" => "add_member",
      "xmtp_inbox_id" => human.xmtp_inbox_id,
      "status" => "done"
    })
    |> Repo.insert!()
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defmodule AnimataHttp do
    @moduledoc false
    @behaviour Autolaunch.AnimataHoldings

    @impl true
    def get(url, _options) do
      if url |> URI.to_string() |> String.contains?("collection=animata") do
        {:ok, %{status: 200, body: %{"nfts" => [%{"identifier" => "7"}]}}}
      else
        {:ok, %{status: 200, body: %{"nfts" => []}}}
      end
    end
  end

  defmodule EnsPrimaryRpc do
    @moduledoc false
    @behaviour AgentEns.Internal.RPC

    @wallet "0xabc0000000000000000000000000000000000011"
    @resolver "0x226159d592e2b063810a10ebf6dcbada94ed68b8"

    @impl true
    def eth_call(_rpc_url, _to, data) do
      case data do
        "0x0178b8bf" <> _rest -> {:ok, address_word(@resolver)}
        "0x691f3431" <> _rest -> {:ok, encode_string("primary-room.eth")}
        "0xf1cb7e06" <> _rest -> {:ok, bool_word(true)}
        "0x02571be3" <> _rest -> {:ok, address_word(@wallet)}
        "0x16a25cbd" <> _rest -> {:ok, uint_word(300)}
        "0x01ffc9a7" <> rest -> {:ok, supports_interface(rest)}
        "0x3b3b57de" <> _rest -> {:ok, address_word(@wallet)}
        _other -> {:ok, uint_word(0)}
      end
    end

    defp supports_interface(rest) do
      if String.starts_with?(rest, "3b3b57de"), do: bool_word(true), else: bool_word(false)
    end

    defp address_word("0x" <> address) do
      "0x" <> String.pad_leading(String.downcase(address), 64, "0")
    end

    defp bool_word(true), do: uint_word(1)
    defp bool_word(false), do: uint_word(0)

    defp uint_word(value), do: "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")

    defp encode_string(value) do
      binary = :erlang.iolist_to_binary(value)
      hex = Base.encode16(binary, case: :lower)
      padding = rem(64 - rem(byte_size(hex), 64), 64)

      "0x" <>
        String.pad_leading("20", 64, "0") <>
        String.pad_leading(Integer.to_string(byte_size(binary), 16), 64, "0") <>
        hex <> String.duplicate("0", padding)
    end
  end
end
