defmodule Autolaunch.PublicChatTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.PublicChat

  import Autolaunch.TestSupport.XmtpSupport, only: [deterministic_inbox_id: 1, unique_suffix: 0]

  defmodule XmtpStub do
    def subscribe, do: :ok
    def topic, do: "Autolaunch.Xmtp.Manager:public-chatbox:refresh"

    def public_room_panel(current_human) do
      {:ok, panel(current_human, :view_only)}
    end

    def request_join(%{display_name: "Full Room"}), do: {:error, :room_full}

    def request_join(current_human) do
      {:needs_signature,
       %{
         request_id: "join-request-1",
         signature_text: "Approve your room seat.",
         wallet_address: current_human.wallet_address,
         panel: panel(current_human, :join_pending_signature)
       }}
    end

    def complete_join_signature(current_human, "join-request-1", "0xsigned") do
      {:ok, panel(current_human, :joined)}
    end

    def complete_join_signature(_current_human, _request_id, _signature) do
      {:error, :signature_request_missing}
    end

    def send_public_message(%{display_name: "Joined"} = current_human, body) do
      trimmed = body |> to_string() |> String.trim()

      cond do
        trimmed == "" ->
          {:error, :message_required}

        String.length(trimmed) > 2_000 ->
          {:error, :message_too_long}

        true ->
          {:ok,
           panel(current_human, :joined, [
             %{
               key: "message-1",
               author: current_human.display_name,
               body: trimmed,
               stamp: "Apr 25 17:30",
               side: :self,
               sender_kind: :human,
               sender_wallet: current_human.wallet_address,
               sender_inbox_id: current_human.xmtp_inbox_id,
               can_delete?: false,
               can_kick?: false
             }
           ])}
      end
    end

    def send_public_message(_current_human, _body), do: {:error, :join_required}

    def heartbeat(_current_human), do: :ok

    defp panel(current_human, membership_state, messages \\ []) do
      joined? = membership_state == :joined
      full? = not is_nil(current_human) and current_human.display_name == "Full Room"
      member_count = if full?, do: 200, else: 0

      %{
        room_key: "public-chatbox",
        room_name: "Autolaunch Room",
        room_id: "conversation-public-chatbox",
        connected_wallet: current_human && current_human.wallet_address,
        ready?: true,
        joined?: joined?,
        can_join?: not joined? and not full? and not is_nil(current_human),
        can_send?: joined?,
        moderator?: false,
        membership_state: if(full?, do: :full, else: membership_state),
        status: nil,
        pending_signature_request_id:
          if(membership_state == :join_pending_signature, do: "join-request-1"),
        member_count: member_count,
        active_member_count: member_count,
        seat_count: 200,
        seats_remaining: 200 - member_count,
        messages: messages
      }
    end
  end

  setup do
    previous_public_chat = Application.get_env(:autolaunch, :public_chat, [])
    Application.put_env(:autolaunch, :public_chat, xmtp_module: XmtpStub)

    on_exit(fn ->
      Application.put_env(:autolaunch, :public_chat, previous_public_chat)
    end)

    :ok
  end

  test "room_panel keeps the public room readable while signed out" do
    panel = PublicChat.room_panel(nil)

    assert panel.room_key == "public-chatbox"
    assert panel.room_name == "Autolaunch Room"
    assert panel.seat_count == 200
    assert panel.ready? == true
    assert panel.can_send? == false
    assert panel.messages == []
  end

  test "joining requires a signed-in person with a prepared room identity" do
    assert {:error, :wallet_required} = PublicChat.request_join(nil)

    assert {:error, :xmtp_identity_required} =
             PublicChat.request_join(create_human!("No Identity", xmtp_identity?: false))
  end

  test "joining returns the wallet approval request from the shared room" do
    human = create_human!("Pending")

    assert {:needs_signature, request} = PublicChat.request_join(human)
    assert request.request_id == "join-request-1"
    assert request.wallet_address == human.wallet_address
    assert request.panel.membership_state == :join_pending_signature

    assert {:ok, panel} =
             PublicChat.complete_join_signature(human, request.request_id, "0xsigned")

    assert panel.joined? == true
  end

  test "room-full state blocks joining but keeps the room readable" do
    human = create_human!("Full Room")

    assert {:error, :room_full} = PublicChat.request_join(human)

    panel = PublicChat.room_panel(human)
    assert panel.member_count == 200
    assert panel.seats_remaining == 0
  end

  test "sending requires room membership and returns shared room messages" do
    assert {:error, :wallet_required} = PublicChat.send_message(nil, "hello")

    assert {:error, :xmtp_identity_required} =
             PublicChat.send_message(create_human!("No Identity", xmtp_identity?: false), "hello")

    assert {:error, :join_required} =
             PublicChat.send_message(create_human!("Not Joined"), "hello")

    assert {:error, :message_required} = PublicChat.send_message(create_human!("Joined"), "   ")

    assert {:error, :message_too_long} =
             PublicChat.send_message(create_human!("Joined"), String.duplicate("a", 2_001))

    human = create_human!("Joined")
    assert {:ok, panel} = PublicChat.send_message(human, "hello from the homepage")
    assert [%{body: "hello from the homepage", side: :self}] = panel.messages
  end

  test "heartbeat is quiet for signed-out and unfinished room identities" do
    assert :ok = PublicChat.heartbeat(nil)
    assert :ok = PublicChat.heartbeat(create_human!("No Identity", xmtp_identity?: false))
    assert :ok = PublicChat.heartbeat(create_human!("Joined"))
  end

  defp create_human!(label, opts \\ []) do
    wallet = "0x#{String.pad_leading(Integer.to_string(unique_suffix(), 16), 40, "0")}"
    xmtp_identity? = Keyword.get(opts, :xmtp_identity?, true)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("privy-public-chat-#{label}-#{unique_suffix()}", %{
        "wallet_address" => wallet,
        "wallet_addresses" => [wallet],
        "xmtp_inbox_id" => if(xmtp_identity?, do: deterministic_inbox_id(wallet)),
        "display_name" => label
      })

    human
  end
end
