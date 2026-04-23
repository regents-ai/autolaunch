defmodule AutolaunchWeb.InternalXmtpControllerTest do
  use AutolaunchWeb.ConnCase, async: false

  alias Autolaunch.Repo
  alias Autolaunch.XMTPMirror.XmtpMembershipCommand

  setup do
    original_secret = Application.get_env(:autolaunch, :internal_shared_secret, "")
    Application.put_env(:autolaunch, :internal_shared_secret, "test-internal-secret")

    on_exit(fn ->
      Application.put_env(:autolaunch, :internal_shared_secret, original_secret)
    end)

    :ok
  end

  test "requires internal shared secret", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/v1/internal/xmtp/rooms/ensure", %{
        "room_key" => "public-chatbox",
        "xmtp_group_id" => "xmtp-public-chatbox",
        "name" => "Public Chatbox",
        "status" => "active"
      })

    assert %{"error" => %{"code" => "internal_auth_required"}} = json_response(conn, 401)
  end

  test "denies request when internal shared secret config is invalid", %{conn: conn} do
    Application.put_env(:autolaunch, :internal_shared_secret, 12_345)

    on_exit(fn ->
      Application.put_env(:autolaunch, :internal_shared_secret, "test-internal-secret")
    end)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/v1/internal/xmtp/rooms/ensure", %{
        "room_key" => "public-chatbox",
        "xmtp_group_id" => "xmtp-public-chatbox",
        "name" => "Public Chatbox",
        "status" => "active"
      })

    assert %{"error" => %{"code" => "internal_auth_required"}} = json_response(conn, 401)
  end

  test "room ensure and message ingest flow works with secret", %{conn: conn} do
    authed_conn = with_secret(conn)

    room_conn =
      post(authed_conn, "/v1/internal/xmtp/rooms/ensure", %{
        "room_key" => "public-chatbox",
        "xmtp_group_id" => "xmtp-public-chatbox",
        "name" => "Public Chatbox",
        "status" => "active"
      })

    assert %{
             "data" => %{
               "room_key" => "public-chatbox",
               "xmtp_group_id" => "xmtp-public-chatbox",
               "name" => "Public Chatbox",
               "status" => "active"
             }
           } = json_response(room_conn, 200)

    message_conn =
      post(authed_conn, "/v1/internal/xmtp/messages/ingest", %{
        "room_key" => "public-chatbox",
        "xmtp_message_id" => "msg-1",
        "sender_inbox_id" => "inbox-1",
        "sender_wallet_address" => "0xsender",
        "sender_label" => "sender",
        "sender_type" => "human",
        "body" => "hello",
        "sent_at" => DateTime.utc_now(),
        "raw_payload" => %{"kind" => "message"},
        "moderation_state" => "visible"
      })

    assert %{"data" => %{"id" => _id}} = json_response(message_conn, 200)
  end

  test "message ingest rejects invalid sent_at", %{conn: conn} do
    authed_conn = with_secret(conn)

    post(authed_conn, "/v1/internal/xmtp/rooms/ensure", %{
      "room_key" => "public-chatbox",
      "xmtp_group_id" => "xmtp-public-chatbox",
      "name" => "Public Chatbox",
      "status" => "active"
    })

    message_conn =
      post(authed_conn, "/v1/internal/xmtp/messages/ingest", %{
        "room_key" => "public-chatbox",
        "xmtp_message_id" => "msg-invalid-time",
        "sender_inbox_id" => "inbox-1",
        "sender_wallet_address" => "0xsender",
        "sender_label" => "sender",
        "sender_type" => "human",
        "body" => "hello",
        "sent_at" => "not-a-timestamp",
        "raw_payload" => %{"kind" => "message"},
        "moderation_state" => "visible"
      })

    assert %{"error" => %{"code" => "invalid_sent_at"}} = json_response(message_conn, 422)
  end

  test "lease and resolve command flow", %{conn: conn} do
    authed_conn = with_secret(conn)

    {:ok, room_conn} =
      ensure_room_and_seed_command(authed_conn, %{
        "op" => "add_member",
        "xmtp_inbox_id" => "inbox-lease"
      })

    room_id = room_conn["id"]

    lease_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/lease", %{
        "room_key" => "public-chatbox"
      })

    assert %{
             "data" => %{
               "id" => leased_id,
               "op" => "add_member",
               "xmtp_inbox_id" => "inbox-lease"
             }
           } = json_response(lease_conn, 200)

    resolve_done_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/#{leased_id}/resolve", %{
        "status" => "done"
      })

    assert %{"ok" => true} = json_response(resolve_done_conn, 200)

    completed = Repo.get!(XmtpMembershipCommand, leased_id)
    assert completed.status == "done"
    assert completed.room_id == room_id

    {:ok, _room} =
      ensure_room_and_seed_command(authed_conn, %{
        "op" => "remove_member",
        "xmtp_inbox_id" => "inbox-fail"
      })

    lease_conn2 =
      post(authed_conn, "/v1/internal/xmtp/commands/lease", %{
        "room_key" => "public-chatbox"
      })

    assert %{"data" => %{"id" => leased_id2}} = json_response(lease_conn2, 200)

    resolve_failed_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/#{leased_id2}/resolve", %{
        "status" => "failed",
        "error" => "simulated failure"
      })

    assert %{"ok" => true} = json_response(resolve_failed_conn, 200)

    failed = Repo.get!(XmtpMembershipCommand, leased_id2)
    assert failed.status == "failed"
    assert failed.last_error == "simulated failure"
  end

  test "lease requires room_key", %{conn: conn} do
    conn =
      conn
      |> with_secret()
      |> post("/v1/internal/xmtp/commands/lease", %{})

    assert %{"error" => %{"code" => "room_key_required"}} = json_response(conn, 422)
  end

  test "resolve returns command_not_found for missing command ids", %{conn: conn} do
    authed_conn = with_secret(conn)

    resolve_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/999999/resolve", %{
        "status" => "done"
      })

    assert %{"error" => %{"code" => "command_not_found"}} = json_response(resolve_conn, 404)
  end

  test "resolve rejects invalid command id format", %{conn: conn} do
    authed_conn = with_secret(conn)

    resolve_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/not-an-id/resolve", %{
        "status" => "done"
      })

    assert %{"error" => %{"code" => "invalid_command_id"}} = json_response(resolve_conn, 422)
  end

  test "resolve command defaults blank errors to membership_command_failed", %{conn: conn} do
    authed_conn = with_secret(conn)

    {:ok, _room} =
      ensure_room_and_seed_command(authed_conn, %{
        "op" => "remove_member",
        "xmtp_inbox_id" => "inbox-default-error"
      })

    lease_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/lease", %{
        "room_key" => "public-chatbox"
      })

    assert %{"data" => %{"id" => leased_id}} = json_response(lease_conn, 200)

    resolve_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/#{leased_id}/resolve", %{
        "status" => "failed",
        "error" => ""
      })

    assert %{"ok" => true} = json_response(resolve_conn, 200)

    failed = Repo.get!(XmtpMembershipCommand, leased_id)
    assert failed.last_error == "membership_command_failed"
  end

  test "resolve command rejects invalid status", %{conn: conn} do
    authed_conn = with_secret(conn)

    {:ok, _room} =
      ensure_room_and_seed_command(authed_conn, %{
        "op" => "remove_member",
        "xmtp_inbox_id" => "inbox-invalid-status"
      })

    lease_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/lease", %{
        "room_key" => "public-chatbox"
      })

    assert %{"data" => %{"id" => leased_id}} = json_response(lease_conn, 200)

    resolve_conn =
      post(authed_conn, "/v1/internal/xmtp/commands/#{leased_id}/resolve", %{
        "status" => "bogus"
      })

    assert %{"error" => %{"code" => "command_resolution_status_invalid"}} =
             json_response(resolve_conn, 422)
  end

  defp with_secret(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("x-autolaunch-secret", "test-internal-secret")
  end

  defp ensure_room_and_seed_command(conn, command_attrs) do
    room_conn =
      post(conn, "/v1/internal/xmtp/rooms/ensure", %{
        "room_key" => "public-chatbox",
        "xmtp_group_id" => "xmtp-public-chatbox",
        "name" => "Public Chatbox",
        "status" => "active"
      })

    %{"data" => room_data} = json_response(room_conn, 200)

    command_changeset =
      XmtpMembershipCommand.enqueue_changeset(%XmtpMembershipCommand{}, %{
        room_id: room_data["id"],
        op: command_attrs["op"],
        xmtp_inbox_id: command_attrs["xmtp_inbox_id"]
      })

    {:ok, _command} = Repo.insert(command_changeset)
    {:ok, room_data}
  end
end
