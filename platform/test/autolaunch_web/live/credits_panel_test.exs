defmodule AutolaunchWeb.CreditsPanelTest do
  use AutolaunchWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Autolaunch.TestSupport

  # CREDITS_PANEL_NO_NODE: ExUnit has no node for Base (config/test.exs), and
  # the Buy Credits panel's USDC reads crashed their tasks with a KeyError from
  # Autolaunch.Chain.NodeClient. A chain with no node is an answer, not a crash:
  # the read fails as one that got no answer and the panel says "unavailable".
  test "CREDITS_PANEL_NO_NODE: a chain with no node reads as unavailable, with no crash", %{
    conn: conn
  } do
    account = TestSupport.register_creator!()
    session = signed_in_session(account.id)
    handler = "credits-panel-no-node-#{inspect(self())}"

    :telemetry.attach(
      handler,
      [:autolaunch, :rpc, :failure],
      &__MODULE__.forward_failure/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log(fn ->
        {:ok, view, _html} =
          conn
          |> Phoenix.ConnTest.init_test_session(session)
          |> connects_with(session)
          |> live("/account")

        render_async(view, 1_000)
        assert view |> element("#credits-panel .credits-panel__usdc") |> render() =~ "unavailable"
      end)

    refute log =~ "KeyError"
    refute log =~ "terminating"
    assert_received {:rpc_failure, %{class: :no_node, chain_id: 8453, method: "eth_call"}}
  end

  def forward_failure(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:rpc_failure, metadata})
end
