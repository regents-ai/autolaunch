defmodule Autolaunch.XmtpTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Xmtp

  @agent_private_key "0x1111111111111111111111111111111111111111111111111111111111111111"

  setup do
    previous_config = Application.get_env(:autolaunch, Xmtp, [])

    Application.put_env(
      :autolaunch,
      Xmtp,
      rooms: [
        %{
          key: "autolaunch_wire",
          name: "Autolaunch Wire",
          description: "The shared Autolaunch chat room.",
          app_data: "autolaunch-wire",
          agent_private_key: @agent_private_key,
          moderator_wallets: [],
          capacity: 200,
          presence_timeout_ms: :timer.minutes(2),
          presence_check_interval_ms: :timer.seconds(30),
          policy_options: %{
            allowed_kinds: [:human, :agent],
            required_claims: %{}
          }
        }
      ]
    )

    :ok = Xmtp.reset_for_test!()

    on_exit(fn ->
      Application.put_env(:autolaunch, Xmtp, previous_config)
      :ok = Xmtp.reset_for_test!()
    end)

    :ok
  end

  test "bootstrap creates the durable room once and reuse keeps the same room" do
    assert {:error, :room_unavailable} = Xmtp.request_join(nil)

    assert {:ok, first} = Xmtp.bootstrap_room!()
    assert is_binary(first.conversation_id)
    assert String.starts_with?(first.agent_wallet_address, "0x")

    assert {:error, :room_already_bootstrapped} = Xmtp.bootstrap_room!()

    assert {:ok, reused} = Xmtp.bootstrap_room!(reuse: true)
    assert reused.conversation_id == first.conversation_id
    assert reused.agent_wallet_address == first.agent_wallet_address
  end

  test "explicit join asks for one signature, then the room stays ready for sending" do
    :ok = bootstrap_room!()

    human =
      create_human!(
        "did:privy:xmtp",
        "0x2222222222222222222222222222222222222222",
        "Wire Operator"
      )

    assert {:ok, panel} = Xmtp.public_room_panel(human)
    assert panel.room_name == "Autolaunch Wire"
    assert panel.membership_state == :view_only
    assert panel.messages == []

    assert {:needs_signature, %{request_id: request_id, signature_text: signature_text}} =
             Xmtp.request_join(human)

    assert is_binary(request_id)
    assert signature_text != ""

    assert {:ok, joined_panel} = Xmtp.complete_join_signature(human, request_id, "0xsigned")
    assert joined_panel.joined?
    assert joined_panel.can_send?
    assert joined_panel.member_count == 1

    assert {:ok, posted_panel} = Xmtp.send_public_message(human, "Hello Autolaunch")
    assert posted_panel.joined?
    assert Enum.any?(posted_panel.messages, &(&1.body == "Hello Autolaunch"))
  end

  test "room updates broadcast through Phoenix PubSub and stay in the website log" do
    :ok = bootstrap_room!()

    human =
      create_human!(
        "did:privy:xmtp-broadcast",
        "0x3333333333333333333333333333333333333333",
        "Broadcast Operator"
      )

    Phoenix.PubSub.subscribe(Autolaunch.PubSub, Xmtp.topic())

    assert {:needs_signature, %{request_id: request_id}} = Xmtp.request_join(human)
    assert {:ok, _panel} = Xmtp.complete_join_signature(human, request_id, "0xdeadbeef")

    assert {:ok, _panel} = Xmtp.send_public_message(human, "Broadcast me")
    assert_receive {:xmtp_public_room, :refresh}, 500

    assert {:ok, guest_panel} = Xmtp.public_room_panel(nil)
    assert Enum.any?(guest_panel.messages, &(&1.body == "Broadcast me"))
  end

  test "room capacity keeps later users in view-only mode until a seat opens" do
    put_xmtp_config(room_capacity: 2)
    :ok = bootstrap_room!()

    first =
      create_human!("did:privy:first", "0x4000000000000000000000000000000000000001", "First")

    second =
      create_human!("did:privy:second", "0x4000000000000000000000000000000000000002", "Second")

    third =
      create_human!("did:privy:third", "0x4000000000000000000000000000000000000003", "Third")

    join_human!(first)
    join_human!(second)

    assert {:ok, full_panel} = Xmtp.public_room_panel(third)
    assert full_panel.membership_state == :full
    refute full_panel.can_join?
    assert full_panel.seats_remaining == 0

    assert {:error, :room_full} = Xmtp.request_join(third)
  end

  test "inactive joined users are kicked after the configured timeout" do
    put_xmtp_config(presence_timeout_ms: 0)
    :ok = bootstrap_room!()

    human =
      create_human!(
        "did:privy:xmtp-timeout",
        "0x5000000000000000000000000000000000000005",
        "Timeout Operator"
      )

    Phoenix.PubSub.subscribe(Autolaunch.PubSub, Xmtp.topic())
    join_human!(human)

    flush_refreshes()
    send(GenServer.whereis(Xmtp.room_server()), :presence_tick)
    assert_receive {:xmtp_public_room, :refresh}, 500

    assert {:ok, kicked_panel} = Xmtp.public_room_panel(human)
    assert kicked_panel.membership_state == :kicked
    refute kicked_panel.can_send?
  end

  test "moderators can tombstone website messages and kick users" do
    moderator_wallet = "0x6000000000000000000000000000000000000006"
    put_xmtp_config(moderator_wallets: [moderator_wallet])
    :ok = bootstrap_room!()

    moderator = create_human!("did:privy:mod", moderator_wallet, "Moderator")
    human = create_human!("did:privy:user", "0x7000000000000000000000000000000000000007", "User")

    join_human!(human)
    assert {:ok, posted_panel} = Xmtp.send_public_message(human, "Needs review")
    message = Enum.find(posted_panel.messages, &(&1.body == "Needs review"))

    assert {:ok, moderator_panel} = Xmtp.moderator_delete_message(moderator, message.key)
    tombstoned = Enum.find(moderator_panel.messages, &(&1.key == message.key))
    assert tombstoned.body == "message deleted by moderator"

    assert {:ok, kicked_panel} = Xmtp.moderator_kick_user(moderator, human.wallet_address)
    assert kicked_panel.moderator?

    assert {:ok, user_panel} = Xmtp.public_room_panel(human)
    assert user_panel.membership_state == :kicked
    refute user_panel.can_send?
  end

  defp bootstrap_room! do
    assert {:ok, _room} = Xmtp.bootstrap_room!()
    :ok
  end

  defp join_human!(human) do
    assert {:needs_signature, %{request_id: request_id}} = Xmtp.request_join(human)
    assert {:ok, panel} = Xmtp.complete_join_signature(human, request_id, "0xsigned")
    panel
  end

  defp create_human!(privy_user_id, wallet_address, display_name) do
    {:ok, human} =
      Accounts.upsert_human_by_privy_id(privy_user_id, %{
        "wallet_address" => wallet_address,
        "wallet_addresses" => [wallet_address],
        "display_name" => display_name
      })

    human
  end

  defp put_xmtp_config(overrides) do
    overrides =
      case Keyword.pop(overrides, :room_capacity) do
        {nil, rest} -> rest
        {capacity, rest} -> Keyword.put(rest, :capacity, capacity)
      end

    [room] = Application.get_env(:autolaunch, Xmtp, []) |> Keyword.fetch!(:rooms)
    Application.put_env(:autolaunch, Xmtp, rooms: [Map.merge(room, Map.new(overrides))])
    :ok = Xmtp.reset_for_test!()
  end

  defp flush_refreshes do
    receive do
      {:xmtp_public_room, :refresh} -> flush_refreshes()
    after
      0 -> :ok
    end
  end
end
