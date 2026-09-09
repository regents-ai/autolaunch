defmodule AutolaunchWeb.WalletPressComponent do
  @moduledoc false
  use AutolaunchWeb, :html
  import Phoenix.LiveView, only: [push_event: 3, send_update: 3]

  # Generation refresh does not change a mounted owning scope. Lineage/account
  # replacement or loss does; no previous private review may survive that cutover.
  def scope(%{
        authenticated: true,
        current_human_id: id,
        session_lease: %{lineage: lineage, account_id: id}
      })
      when is_integer(id) and is_binary(lineage),
      do: Autolaunch.Accounts.SessionAuthority.topic(lineage) <> ":" <> to_string(id)

  def scope(_assigns), do: nil

  def withdrawal_copy,
    do:
      "This review was cancelled. Previously issued wallet presses may still complete; check their recorded outcomes. No new presses can start from this review."

  def update_scope(socket, incoming) do
    next = Map.merge(socket.assigns, incoming)

    if scope(socket.assigns) != scope(next) or is_nil(scope(next)),
      do: clear_private(socket),
      else: socket
  end

  defp clear_private(socket) do
    assign(socket,
      wallet_press_history: %{},
      operation: nil,
      wallet: nil,
      balance: nil,
      state: nil,
      amount: "",
      max_price: "",
      usdc_amount: "",
      usdc_max_price: "",
      estimate: nil,
      note: "",
      notice: nil,
      fresh_treasury_report_id: nil
    )
  end

  def dispatch(socket, kind, params, opts, component) do
    async(
      socket,
      component,
      fn ->
        Autolaunch.dispatch_wallet_press(
          kind,
          params["action_id"],
          params["step"],
          params["press_id"],
          params["signer"],
          opts
        )
      end,
      {:dispatch, params}
    )
  end

  def legacy_report(socket, kind, params, opts, component, event) do
    case Autolaunch.WalletAttempts.report_legacy(
           kind,
           params["action_id"],
           params["step"],
           params["transaction_hash"],
           opts
         ) do
      {:ok, %{attempt: attempt}} = result ->
        socket =
          apply_result(socket, result)
          |> push_event(event, %{
            action_id: params["action_id"],
            step: params["step"],
            transaction_hash: params["transaction_hash"],
            component_id: socket.assigns.id
          })

        verify(socket, kind, Map.put(params, "press_id", attempt.id), opts, component)

      error ->
        completed(socket, {:legacy, error})
    end
  end

  def report(socket, kind, params, opts, component) do
    # Acknowledgement is not delayed behind RPC. Verification gets its own task,
    # without an operation-wide task name that could cancel a sibling's result.
    case Autolaunch.report_wallet_press(
           kind,
           params["action_id"],
           params["press_id"],
           params,
           opts
         ) do
      {:ok, _} = result ->
        socket = apply_result(socket, result) |> push_event("wallet-press:durable", params)

        if params["transaction_hash"],
          do: verify(socket, kind, params, opts, component),
          else: socket

      error ->
        apply_result(socket, error)
    end
  end

  def verify(socket, kind, params, opts, component),
    do:
      async(
        socket,
        component,
        fn ->
          Autolaunch.verify_wallet_press(kind, params["action_id"], params["press_id"], opts)
        end,
        :verify
      )

  def restore(socket, kind, params, opts),
    do: apply_result(socket, Autolaunch.wallet_presses(kind, params["action_id"], opts))

  defp async(socket, component, fun, tag) do
    pid = self()
    id = socket.assigns.id
    lease = socket.assigns.session_lease

    Task.start(fn ->
      send_update(pid, component,
        id: id,
        wallet_press_lease: lease,
        wallet_press_result: {tag, fun.()}
      )
    end)

    socket
  end

  def consume(socket, lease, result) do
    cond do
      socket.assigns[:session_lease] != lease ->
        socket

      current_authority?(socket.assigns) ->
        completed(socket, result)

      true ->
        socket
        |> clear_private()
        |> assign(authenticated: false, current_human_id: nil, session_lease: nil)
        |> push_event("wallet-press:invalidated", %{component_id: socket.assigns.id})
    end
  end

  defp current_authority?(%{
         authenticated: true,
         current_human_id: id,
         session_lease: %{lineage: lineage, account_id: id}
       }) do
    match?(%{id: ^id}, Autolaunch.Accounts.SessionAuthority.leased_account(lineage, id))
  end

  defp current_authority?(_assigns), do: false

  def completed(socket, {{:dispatch, params}, {:ok, %{dispatch?: true}} = result}) do
    socket
    |> apply_result(result)
    |> push_event(
      "wallet-press:send",
      Map.put(params, "component_id", socket.assigns.id)
    )
  end

  def completed(socket, {_tag, result}) do
    socket
    |> apply_result(result)
    |> push_event("wallet-press:updated", %{component_id: socket.assigns.id})
  end

  defp apply_result(socket, {:ok, %{operation: operation}}) do
    previous = Map.get(socket.assigns[:wallet_press_history] || %{}, operation.action_id)

    previous =
      case socket.assigns[:operation] do
        %{action_id: id} = current when id == operation.action_id ->
          merge_observation(previous, current)

        _ ->
          previous
      end

    operation = merge_observation(previous, operation)

    history =
      Map.put(socket.assigns[:wallet_press_history] || %{}, operation.action_id, operation)

    socket = assign(socket, :wallet_press_history, history)
    # A delayed A result is visible in A's history, never the current B review.
    case socket.assigns[:operation] do
      %{action_id: id} when id == operation.action_id -> assign(socket, :operation, operation)
      _ -> socket
    end
  end

  defp apply_result(socket, {:error, reason}) do
    message =
      case reason do
        :chain_unavailable ->
          "Base could not be read just now. Try again in a moment."

        %Ash.Error.Invalid.Unavailable{reason: :legacy_press_not_found} ->
          "That transaction is not the step this bid is waiting for."

        _ ->
          "This wallet press could not be updated. Sign in again or check its recorded transaction."
      end

    assign(socket, :notice, %{tone: :error, message: message})
  end

  # Independent tasks may deliver committed snapshots out of order. Merge the
  # per-row versions, not the arrival order, so an old dispatch response cannot
  # hide a sibling or turn a confirmed receipt back into a pending prompt.
  defp merge_observation(nil, incoming), do: incoming

  defp merge_observation(previous, incoming) do
    view =
      if DateTime.compare(previous.revision, incoming.revision) == :gt,
        do: previous,
        else: incoming

    attempts =
      (previous.attempts ++ incoming.attempts)
      |> Enum.reduce(%{}, fn row, rows ->
        Map.update(rows, row.id, row, fn old ->
          if DateTime.compare(old.updated_at, row.updated_at) == :gt, do: old, else: row
        end)
      end)
      |> Map.values()
      |> Enum.sort_by(&{&1.inserted_at, &1.id})

    view =
      if is_nil(view.terminal_at) do
        active = Enum.filter(attempts, &(&1.step == view.step))

        state =
          cond do
            Enum.any?(active, &(&1.state == :submitted)) -> :submitted
            Enum.any?(active, &(&1.state in [:dispatched, :submission_unknown])) -> :dispatched
            true -> :prepared
          end

        Map.put(view, :state, state)
      else
        view
      end

    Map.put(view, :attempts, attempts)
  end

  attr :history, :map, required: true
  attr :target, :any, required: true

  def history(assigns) do
    ~H"""
    <section :if={map_size(@history) > 0} aria-label="Wallet press outcomes" aria-live="polite">
      <div :for={{action_id, operation} <- Enum.sort(@history)}>
        <p :for={attempt <- Map.get(operation, :attempts, [])} data-wallet-press={attempt.id}>
          <span>{attempt.step}: {attempt.state}</span>
          <code :if={attempt.transaction_hash}>{attempt.transaction_hash}</code>
          <span :if={attempt.result["onchain_bid_id"]}>Bid {attempt.result["onchain_bid_id"]}</span>
          <span :if={attempt.result["auction"]}>Auction {attempt.result["auction"]}</span>
          <Regent.Primitives.button
            :if={attempt.transaction_hash && attempt.state == :submitted}
            type="button"
            phx-click="wallet_press_verify"
            phx-value-action_id={action_id}
            phx-value-press_id={attempt.id}
            phx-target={@target}
            variant="secondary"
          >Check transaction</Regent.Primitives.button>
        </p>
      </div>
    </section>
    """
  end
end
