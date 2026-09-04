defmodule AutolaunchWeb.BuybackLiveTest do
  use AutolaunchWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System
  alias Autolaunch.TestSupport

  @wallet "0x1111111111111111111111111111111111111111"
  @treasury "0x3333333333333333333333333333333333333333"
  @subject_id "0x" <> String.duplicate("42", 32)
  @transaction_hash "0x" <> String.duplicate("ab", 32)

  @removed_events [
    {"prepare_autolaunch_buyback",
     %{
       "buyback" => %{"amount_usdc" => "11", "minimum_regent_output" => "10"}
     }},
    {"sign_prepared_autolaunch_buyback", %{"action-id" => "buyback-action"}},
    {"autolaunch_buyback_submitted",
     %{"action_id" => "buyback-action", "transaction_hash" => @transaction_hash}},
    {"restore_autolaunch_buyback_submission",
     %{"envelope" => %{}, "transaction_hash" => @transaction_hash}},
    {"confirm_autolaunch_buyback",
     %{"action_id" => "buyback-action", "transaction_hash" => @transaction_hash}},
    {"retry_autolaunch_buyback_confirmation", %{}},
    {"cancel_autolaunch_buyback_review", %{}},
    {"autolaunch_buyback_wallet_failed", %{"message" => "cancelled"}}
  ]

  setup do
    account =
      Accounts.register_verified!(
        "did:privy:autolaunch-buyback-live:#{Elixir.System.unique_integer([:positive])}",
        @wallet,
        [@wallet],
        actor: %System{}
      )

    subject =
      TestSupport.project_subject(
        subject_id: @subject_id <> ":#{Elixir.System.unique_integer([:positive])}",
        treasury_address: @treasury,
        creator_address: @wallet,
        pending_buyback_usdc_raw: "11000000"
      )

    %{account: account, subject: subject}
  end

  test "subject page remains read-only while preserving historical settlement facts", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    {:ok, view, html} = subject_live(conn, account, subject)

    assert has_element?(view, "#subject-settlement-history", "Pending buyback")
    assert html =~ "11000000"

    for selector <- [
          "#subject-buyback-wallet",
          "#subject-buyback-form",
          "#subject-buyback-review",
          "#subject-payment-wallet",
          "#subject-payment-review"
        ] do
      refute has_element?(view, selector)
    end

    for copy <- [
          "Settle a pending buyback",
          "Ready to settle",
          "Payment links, revenue, and subject staking",
          "AutolaunchBuybackWallet",
          "AutolaunchSubjectPaymentWallet"
        ] do
      refute html =~ copy
    end
  end

  test "direct buyback lifecycle injection has no LiveView handler", %{
    conn: conn,
    account: account,
    subject: subject
  } do
    for {event, params} <- @removed_events do
      {:ok, view, _html} = subject_live(conn, account, subject)

      assert_removed_event(view, event, params)
    end
  end

  defp subject_live(conn, account, subject) do
    {:ok, view, _html} =
      conn
      |> init_test_session(%{human_account_id: account.id})
      |> live("/subjects/#{subject.subject_id}")

    html = render_async(view, 5_000)
    {:ok, view, html}
  end

  defp assert_removed_event(view, event, params) do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      capture_log(fn -> assert catch_exit(render_hook(view, event, params)) end)
    after
      flush_exit_messages()
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp flush_exit_messages do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit_messages()
    after
      0 -> :ok
    end
  end
end
