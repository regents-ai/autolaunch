defmodule AutolaunchWeb.WalletPressComponentTest do
  use AutolaunchWeb.ConnCase, async: false

  alias AutolaunchWeb.{BidComponent, LaunchWalletComponent, SubjectWalletComponent}

  @wallet "0x1111111111111111111111111111111111111111"
  @hash "0x" <> String.duplicate("aa", 32)

  setup do
    account = Autolaunch.Accounts.register_verified!(
      "did:privy:frontend-scope:#{System.unique_integer([:positive])}", @wallet, [@wallet],
      actor: %Autolaunch.Actors.System{})
    lease = current_lease(account.id)
    now = DateTime.utc_now()
    row = %{id: Ecto.UUID.generate(), step: :bid, state: :submitted,
      transaction_hash: @hash, result: %{}, inserted_at: now, updated_at: now}
    operation = %{action_id: Ecto.UUID.generate(), revision: now, terminal_at: nil,
      step: :bid, state: :submitted, attempts: [row]}
    assigns = %{id: "panel", authenticated: true, current_human_id: account.id,
      session_lease: lease, wallet: @wallet, operation: operation,
      wallet_press_history: %{operation.action_id => operation}, notice: nil,
      draft: %{treasury: @wallet}, myself: %Phoenix.LiveComponent.CID{cid: 1}}
    %{assigns: assigns, operation: operation}
  end

  for component <- [BidComponent, LaunchWalletComponent, SubjectWalletComponent] do
    test "#{component} clears private state on ordinary scope replacement and loss", %{assigns: assigns} do
      component = unquote(component)
      for replacement <- [
        %{authenticated: false, current_human_id: nil, session_lease: nil},
        %{authenticated: true, current_human_id: assigns.current_human_id + 1,
          session_lease: %{lineage: "replacement", account_id: assigns.current_human_id + 1}},
        %{authenticated: true, current_human_id: assigns.current_human_id,
          session_lease: current_lease(assigns.current_human_id)}
      ] do
        socket = socket(assigns)
        {:ok, updated} = component.update(Map.merge(Map.take(assigns, [:id, :draft]), replacement), socket)
        assert updated.assigns.operation == nil
        assert updated.assigns.wallet_press_history == %{}
        assert updated.assigns.wallet == nil
        html = component.render(updated.assigns) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
        refute html =~ @hash
        refute html =~ "data-wallet-press="
      end
    end

    test "#{component} never renders private history without authority even if populated", %{assigns: assigns} do
      component = unquote(component)
      {:ok, initialized} = component.update(Map.drop(assigns, [:myself]), socket(%{myself: assigns.myself}))
      private = initialized.assigns |> Map.merge(%{authenticated: false, current_human_id: nil,
        session_lease: nil, wallet: nil, operation: nil})
      html = component.render(private) |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
      refute html =~ @hash
      refute html =~ "data-wallet-press="
    end

    test "#{component} preserves same-scope state across generation refresh", %{assigns: assigns} do
      refreshed = Map.put(assigns.session_lease, :generation_at_mount, 2)
      {:ok, updated} = unquote(component).update(%{id: assigns.id, draft: assigns.draft,
        session_lease: refreshed}, socket(assigns))
      assert updated.assigns.operation == assigns.operation
      assert updated.assigns.wallet_press_history == assigns.wallet_press_history
    end
  end

  test "late same-action observation merges against synchronous terminal current revision", %{assigns: assigns, operation: old} do
    now = DateTime.add(old.revision, 1, :second)
    current = %{old | state: :cancelled, terminal_at: now, revision: now}
    [row] = old.attempts
    sibling = %{row | id: Ecto.UUID.generate()}
    incoming = %{old | attempts: [row, sibling]}
    {:ok, updated} = BidComponent.update(%{wallet_press_lease: assigns.session_lease,
      wallet_press_result: {{:dispatch, %{"action_id" => old.action_id, "press_id" => sibling.id, "step" => "bid"}},
        {:ok, %{operation: incoming, dispatch?: true}}}}, socket(%{assigns | operation: current}))
    assert updated.assigns.operation.state == :cancelled
    assert updated.assigns.operation.terminal_at == now
    assert Enum.count(updated.assigns.operation.attempts) == 2
    assert updated.assigns.wallet_press_history[old.action_id].state == :cancelled
    # Withdrawal closes future admission, not a previously authorized sibling.
    assert Enum.any?(updated.private.live_temp[:push_events], fn [event, _] -> event == "wallet-press:send" end)
  end

  defp socket(assigns), do: %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
end
