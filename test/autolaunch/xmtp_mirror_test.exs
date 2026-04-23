defmodule Autolaunch.XMTPMirrorTest do
  use Autolaunch.DataCase, async: false

  alias Autolaunch.Accounts
  alias Autolaunch.Repo
  alias Autolaunch.XMTPMirror
  alias Autolaunch.XMTPMirror.{XmtpMembershipCommand, XmtpMessage, XmtpPresence, XmtpRoom}
  import Autolaunch.TestSupport.XmtpSupport, only: [deterministic_inbox_id: 1, unique_suffix: 0]

  @canonical_room_key "public-chatbox"

  test "request_join enqueues add_member idempotently and does not double-enqueue while processing" do
    room = create_canonical_room!()
    human = create_human!("join")

    assert {:ok, %{status: "pending", human_id: human_id}} = XMTPMirror.request_join(human)
    assert human_id == human.id
    assert command_count(room.id, human.id, "add_member") == 1

    assert {:ok, %{status: "pending", human_id: ^human_id}} = XMTPMirror.request_join(human)
    assert command_count(room.id, human.id, "add_member") == 1

    leased = XMTPMirror.lease_next_command(@canonical_room_key)
    assert leased.op == "add_member"
    assert leased.status == "processing"

    assert {:ok, %{status: "pending", human_id: ^human_id}} = XMTPMirror.request_join(human)
    assert command_count(room.id, human.id, "add_member") == 1
  end

  test "request_join requires a stored chat identity" do
    _room = create_canonical_room!()

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("privy-missing-inbox-#{unique_suffix()}", %{
        "wallet_address" => "0x1111111111111111111111111111111111111111",
        "wallet_addresses" => ["0x1111111111111111111111111111111111111111"],
        "display_name" => "human-missing-inbox"
      })

    assert %{room_present: true, state: "setup_required"} = XMTPMirror.membership_for(human)
    assert {:error, :xmtp_identity_required} = XMTPMirror.request_join(human)
  end

  test "request_join is a no-op when membership is already joined" do
    room = create_canonical_room!()
    human = create_human!("joined")

    done_add = insert_membership_command!(room, human, "add_member", "done")

    assert {:ok, %{status: "joined", human_id: human_id}} = XMTPMirror.request_join(human)
    assert human_id == human.id
    assert Repo.aggregate(XmtpMembershipCommand, :count, :id) == 1
    assert Repo.get!(XmtpMembershipCommand, done_add.id).status == "done"
  end

  test "request_join allocates the next shard when the canonical shard is full" do
    canonical_room = create_canonical_room!()
    saturate_room!(canonical_room, 200)
    human = create_human!("overflow")

    assert {:ok, %{room_key: room_key, shard_key: shard_key, status: "pending"}} =
             XMTPMirror.request_join(human)

    assert room_key == "public-chatbox-shard-2"
    assert shard_key == room_key
    assert Repo.get_by!(XmtpRoom, room_key: room_key)
    assert command_count(canonical_room.id, human.id, "add_member") == 0
  end

  test "list_shards includes capacity and joinability state" do
    canonical_room = create_canonical_room!()
    _second_room = create_room!("public-chatbox-shard-2")
    saturate_room!(canonical_room, 200)

    shards = XMTPMirror.list_shards()

    assert Enum.any?(shards, fn shard ->
             shard.room_key == "public-chatbox" and shard.capacity == 200 and
               shard.active_members == 200 and shard.joinable == false
           end)

    assert Enum.any?(shards, fn shard ->
             shard.room_key == "public-chatbox-shard-2" and shard.capacity == 200 and
               shard.joinable == true
           end)
  end

  test "heartbeat enqueues stale membership eviction for expired presences" do
    room = create_canonical_room!()
    live_human = create_human!("live")
    stale_human = create_human!("stale")

    insert_membership_command!(room, live_human, "add_member", "done")
    insert_membership_command!(room, stale_human, "add_member", "done")

    insert_stale_presence!(room, stale_human)

    assert {:ok, %{status: "alive", eviction_enqueued: eviction_enqueued}} =
             XMTPMirror.heartbeat_presence(live_human)

    assert eviction_enqueued == 1

    assert %XmtpMembershipCommand{op: "remove_member", status: "pending"} =
             XmtpMembershipCommand
             |> where(
               [c],
               c.room_id == ^room.id and c.human_user_id == ^stale_human.id and
                 c.op == "remove_member"
             )
             |> order_by([c], desc: c.inserted_at, desc: c.id)
             |> limit(1)
             |> Repo.one!()

    assert %XmtpPresence{evicted_at: %DateTime{}} =
             Repo.get_by!(XmtpPresence,
               room_id: room.id,
               xmtp_inbox_id: stale_human.xmtp_inbox_id
             )
  end

  test "lease_next_command only leases one pending command across concurrent workers" do
    room = create_canonical_room!()
    human = create_human!("lease-race")
    command = insert_membership_command!(room, human, "add_member", "pending")
    command_id = command.id

    task_one = Task.async(fn -> XMTPMirror.lease_next_command(@canonical_room_key) end)
    task_two = Task.async(fn -> XMTPMirror.lease_next_command(@canonical_room_key) end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task_one.pid)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task_two.pid)

    leased_results = [Task.await(task_one), Task.await(task_two)]

    assert Enum.count(leased_results, &match?(%XmtpMembershipCommand{id: ^command_id}, &1)) == 1
    assert Enum.count(leased_results, &is_nil/1) == 1
    assert Repo.get!(XmtpMembershipCommand, command.id).status == "processing"
  end

  test "heartbeat enqueues a fresh stale-member removal after an earlier removal already finished" do
    room = create_canonical_room!()
    live_human = create_human!("live-repeat")
    stale_human = create_human!("stale-repeat")

    insert_membership_command!(room, live_human, "add_member", "done")
    insert_membership_command!(room, stale_human, "remove_member", "done")
    insert_membership_command!(room, stale_human, "add_member", "done")
    insert_stale_presence!(room, stale_human)

    assert {:ok, %{eviction_enqueued: 1}} = XMTPMirror.heartbeat_presence(live_human)

    remove_commands =
      XmtpMembershipCommand
      |> where(
        [command],
        command.room_id == ^room.id and command.human_user_id == ^stale_human.id and
          command.op == "remove_member"
      )
      |> order_by([command], asc: command.inserted_at, asc: command.id)
      |> Repo.all()

    assert length(remove_commands) == 2
    assert Enum.at(remove_commands, 0).status == "done"
    assert Enum.at(remove_commands, 1).status == "pending"
    assert Enum.at(remove_commands, 1).xmtp_inbox_id == stale_human.xmtp_inbox_id
  end

  test "membership_for reflects room presence and latest command state" do
    human = create_human!("membership")

    assert %{
             human_id: human_id,
             room_key: @canonical_room_key,
             room_present: false,
             state: "room_unavailable"
           } = XMTPMirror.membership_for(human)

    assert human_id == human.id

    room = create_canonical_room!()

    assert %{room_present: true, state: "not_joined"} = XMTPMirror.membership_for(human)

    add_pending = insert_membership_command!(room, human, "add_member", "pending")
    assert %{state: "join_pending"} = XMTPMirror.membership_for(human)

    assert :ok = XMTPMirror.resolve_command(add_pending.id, %{status: "done"})
    assert %{state: "joined"} = XMTPMirror.membership_for(human)

    remove_pending = insert_membership_command!(room, human, "remove_member", "pending")
    assert %{state: "leave_pending"} = XMTPMirror.membership_for(human)

    assert :ok =
             XMTPMirror.resolve_command(remove_pending.id, %{
               status: "failed",
               error: "membership op failed"
             })

    assert %{state: "leave_failed"} = XMTPMirror.membership_for(human)

    remove_done = insert_membership_command!(room, human, "remove_member", "pending")
    assert :ok = XMTPMirror.resolve_command(remove_done.id, %{status: "done"})
    assert %{state: "not_joined"} = XMTPMirror.membership_for(human)
  end

  test "add and remove on the canonical room enqueue moderation-safe membership ops idempotently" do
    room = create_canonical_room!()
    human = create_human!("moderation")

    assert {:ok, :enqueued} = XMTPMirror.add_human_to_canonical_room(human.id)
    assert command_count(room.id, human.id, "add_member") == 1

    assert {:ok, :already_pending_join} = XMTPMirror.add_human_to_canonical_room(human.id)
    assert command_count(room.id, human.id, "add_member") == 1

    _leased = XMTPMirror.lease_next_command(@canonical_room_key)
    assert {:ok, :already_pending_join} = XMTPMirror.add_human_to_canonical_room(human.id)
    assert command_count(room.id, human.id, "add_member") == 1

    assert :ok =
             XMTPMirror.resolve_command(
               latest_command_id!(room.id, human.id, "add_member"),
               %{status: "done"}
             )

    assert {:ok, :enqueued} = XMTPMirror.remove_human_from_canonical_room(human.id)
    assert command_count(room.id, human.id, "remove_member") == 1

    assert {:ok, :already_pending_removal} = XMTPMirror.remove_human_from_canonical_room(human.id)
    assert command_count(room.id, human.id, "remove_member") == 1
  end

  test "remove_human_from_canonical_room requires the current ready inbox" do
    room = create_canonical_room!()
    human = create_human!("stale-remove")

    _joined = insert_membership_command!(room, human, "add_member", "done")
    insert_stale_presence!(room, human)

    {:ok, stale_human} = Accounts.update_human(human, %{"xmtp_inbox_id" => nil})

    assert {:error, :xmtp_identity_required} =
             XMTPMirror.remove_human_from_canonical_room(stale_human.id)

    assert command_count(room.id, human.id, "remove_member") == 0
  end

  test "ingest_message is idempotent for repeated xmtp_message_id and listing excludes hidden" do
    room = create_canonical_room!()
    tie_timestamp = ~U[2026-03-01 12:00:00.000000Z]
    latest_timestamp = ~U[2026-03-01 12:00:01.000000Z]

    attrs = %{
      room_id: room.id,
      xmtp_message_id: "msg-1",
      sender_inbox_id: "inbox-1",
      sender_wallet_address: "0x1111111111111111111111111111111111111111",
      sender_label: "sender",
      sender_type: :human,
      body: "hello",
      sent_at: tie_timestamp,
      raw_payload: %{"kind" => "message"},
      moderation_state: "visible"
    }

    {:ok, first} = XMTPMirror.ingest_message(attrs)
    {:ok, second} = XMTPMirror.ingest_message(attrs)
    assert first.id == second.id

    tie_second = insert_message!(room, "tie-second", tie_timestamp, "visible")
    newest = insert_message!(room, "newest", latest_timestamp, "visible")
    _hidden = insert_message!(room, "hidden", latest_timestamp, "hidden")

    messages = XMTPMirror.list_public_messages(%{"limit" => "10"})
    assert Enum.map(messages, & &1.id) == [newest.id, tie_second.id, first.id]
  end

  test "ingest_message rejects missing or invalid sent_at" do
    room = create_canonical_room!()

    attrs = %{
      room_id: room.id,
      xmtp_message_id: "msg-invalid-time",
      sender_inbox_id: "inbox-invalid-time",
      sender_wallet_address: "0x1111111111111111111111111111111111111111",
      sender_label: "sender",
      sender_type: :human,
      body: "hello",
      raw_payload: %{"kind" => "message"},
      moderation_state: "visible"
    }

    assert {:error, :invalid_sent_at} = XMTPMirror.ingest_message(attrs)

    assert {:error, :invalid_sent_at} =
             XMTPMirror.ingest_message(Map.put(attrs, :sent_at, "nope"))

    assert Repo.aggregate(XmtpMessage, :count, :id) == 0
  end

  test "create_human_message rejects missing or invalid sent_at" do
    _room = create_canonical_room!()
    human = create_human!("human-message-time")

    assert {:error, :invalid_sent_at} =
             XMTPMirror.create_human_message(human, %{body: "hello", sent_at: nil})

    assert {:error, :invalid_sent_at} =
             XMTPMirror.create_human_message(human, %{body: "hello", sent_at: "nope"})
  end

  test "resolve_command returns clean errors for bad ids" do
    assert {:error, :invalid_command_id} = XMTPMirror.resolve_command("bad-id", %{status: "done"})
    assert {:error, :command_not_found} = XMTPMirror.resolve_command(999_999, %{status: "done"})
  end

  defp create_canonical_room! do
    create_room!(@canonical_room_key)
  end

  defp create_room!(room_key) do
    %XmtpRoom{}
    |> XmtpRoom.changeset(%{
      room_key: room_key,
      name: "Room #{room_key}",
      status: "active",
      xmtp_group_id: "group-#{room_key}-#{unique_suffix()}"
    })
    |> Repo.insert!()
  end

  defp create_human!(prefix) do
    wallet_address = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    {:ok, human} =
      Accounts.upsert_human_by_privy_id("privy-#{prefix}-#{unique_suffix()}", %{
        "wallet_address" => wallet_address,
        "wallet_addresses" => [wallet_address],
        "xmtp_inbox_id" => deterministic_inbox_id(wallet_address),
        "display_name" => "#{prefix}-#{unique_suffix()}"
      })

    human
  end

  defp insert_membership_command!(room, human, op, status) do
    %XmtpMembershipCommand{}
    |> XmtpMembershipCommand.enqueue_changeset(%{
      room_id: room.id,
      human_user_id: human.id,
      op: op,
      xmtp_inbox_id: human.xmtp_inbox_id,
      status: status
    })
    |> Repo.insert!()
  end

  defp insert_stale_presence!(room, human) do
    %XmtpPresence{}
    |> XmtpPresence.changeset(%{
      room_id: room.id,
      human_user_id: human.id,
      xmtp_inbox_id: human.xmtp_inbox_id,
      last_seen_at: ~U[2026-03-01 11:57:00.000000Z],
      expires_at: ~U[2026-03-01 11:58:00.000000Z]
    })
    |> Repo.insert!()
  end

  defp insert_message!(room, label, sent_at, moderation_state) do
    %XmtpMessage{}
    |> XmtpMessage.changeset(%{
      room_id: room.id,
      xmtp_message_id: "msg-#{label}-#{unique_suffix()}",
      sender_inbox_id: "inbox-#{label}-#{unique_suffix()}",
      sender_wallet_address: "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower),
      sender_label: label,
      sender_type: :human,
      body: label,
      sent_at: sent_at,
      moderation_state: moderation_state,
      raw_payload: %{"kind" => "message"},
      reactions: %{}
    })
    |> Repo.insert!()
  end

  defp saturate_room!(room, capacity) do
    Enum.each(1..capacity, fn idx ->
      wallet_address = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

      {:ok, human} =
        Accounts.upsert_human_by_privy_id("privy-saturated-#{room.id}-#{idx}", %{
          "wallet_address" => wallet_address,
          "wallet_addresses" => [wallet_address],
          "xmtp_inbox_id" => deterministic_inbox_id(wallet_address),
          "display_name" => "saturated-#{idx}"
        })

      insert_membership_command!(room, human, "add_member", "done")
    end)
  end

  defp command_count(room_id, human_id, op) do
    XmtpMembershipCommand
    |> where([c], c.room_id == ^room_id and c.human_user_id == ^human_id and c.op == ^op)
    |> Repo.aggregate(:count, :id)
  end

  defp latest_command_id!(room_id, human_id, op) do
    XmtpMembershipCommand
    |> where([c], c.room_id == ^room_id and c.human_user_id == ^human_id and c.op == ^op)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(1)
    |> select([c], c.id)
    |> Repo.one!()
  end
end
