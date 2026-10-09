defmodule AutolaunchWeb.FinishAuctionComponent do
  @moduledoc """
  The Finish button on an ended auction's page.

  Once bidding has ended, an auction waits for someone to finish it: the
  launch's `migrate`, open to anyone from its migration block on, which opens
  the pool or, below the minimum, opens refunds (`Autolaunch.FinishActions`).
  The card reads the launch at the latest block when it appears, again every
  half minute while the migration block is still ahead or the chain could not
  be read, and once more when a finish sent from it is confirmed.

  The wallet that sends is Privy's active wallet when the signed-in account
  links it (`AutolaunchWeb.OnchainSteps`); any of the account's wallets may
  finish. The review is built as soon as the card knows that wallet, so the
  button sends at once. The button is disabled only when the chain says the
  finish would fail: before the migration block, or once the launch is
  finished. Nothing is stored; the market feeds record the outcome from the
  chain and the page follows them.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Chain.Client
  alias Autolaunch.FinishActions
  alias AutolaunchWeb.Components.SwapForm
  alias AutolaunchWeb.OnchainSteps
  alias RegentChain.{Presses, Review}

  @recheck_ms 30_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> OnchainSteps.init(&followed/1)
     |> assign(signer: nil, mismatch: nil, launch: nil, unread: false, asked: false, timer: nil)}
  end

  @impl true
  def update(%{reread: true}, socket), do: {:ok, socket |> assign(timer: nil) |> read()}

  def update(assigns, socket) do
    socket = socket |> assign(assigns) |> OnchainSteps.adopt() |> followed()
    {:ok, if(socket.assigns.asked, do: socket, else: read(socket))}
  end

  # The card follows the wallet that may act; a review is built for one signer.
  defp followed(socket) do
    %{linked: linked, active: active} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    socket = assign(socket, mismatch: OnchainSteps.mismatch_note(linked, active))

    if signer == socket.assigns.signer,
      do: socket,
      else: socket |> assign(signer: signer) |> reviewed()
  end

  @impl true
  def render(assigns) do
    step = step(assigns)
    blocked = blocked(assigns.launch)

    assigns =
      assign(assigns,
        steps: if(step && !blocked, do: [step], else: []),
        next_step: next_step(step, blocked),
        blocked: blocked,
        chain_name: chain_name(assigns),
        progress: progress(step, chain_name(assigns))
      )

    ~H"""
    <section
      id={@id}
      class="finish-auction"
      phx-hook="OnchainSteps"
      aria-label="Finish this auction"
    >
      <h3>Finish this auction</h3>
      <p class="finish-auction__about">
        Finishing opens the pool, or opens refunds if the minimum wasn't met. Anyone can do it for the network fee.
      </p>
      <p class="finish-auction__line" role="status" aria-live="polite">
        {line(@blocked, @progress, @unread, @launch)}
      </p>
      <p class="bid-notice" role="status" hidden={!@press_note}>{@press_note}</p>
      <SwapForm.wallet_step
        next_step={@next_step}
        steps={@steps}
        reverted={reverted(@steps)}
        signer={@review && @review.signer}
        chain_name={@chain_name}
        mismatch={@mismatch}
        check_event="check_again"
        target={@myself}
      />
      <Regent.Primitives.button type="button" class="token-swap__submit" disabled hidden={!@blocked}>
        Finish auction
      </Regent.Primitives.button>
    </section>
    """
  end

  @impl true
  def handle_event("onchain_active_wallet", params, socket) do
    active = OnchainSteps.active_wallet(params)

    socket =
      if active == socket.assigns.active,
        do: socket,
        else: assign(socket, active: active, press_note: nil)

    {:noreply, followed(socket)}
  end

  def handle_event("step_sent", params, socket),
    do: {:noreply, OnchainSteps.sent(socket, params)}

  def handle_event("step_failed", params, socket) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        AutolaunchWeb.Telemetry.wallet_failed(:finish_auction, reason)
        %{linked: linked, active: active} = socket.assigns

        {:noreply,
         assign(socket,
           press_note:
             OnchainSteps.failure_note(reason, linked, active, chain_name(socket.assigns))
         )}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_again", %{"hash" => hash}, socket) when is_binary(hash),
    do: {:noreply, OnchainSteps.check_again(socket, hash)}

  @impl true
  def handle_async(:launch, {:ok, {:ok, launch}}, socket) do
    socket = socket |> assign(launch: launch, unread: false) |> reviewed()
    if waiting?(launch), do: {:noreply, recheck_later(socket)}, else: {:noreply, socket}
  end

  def handle_async(:launch, _unread, socket),
    do: {:noreply, socket |> assign(unread: true) |> recheck_later()}

  # A finish that lands is read back at once: confirmed, the button turns to
  # finished; reverted, the launch may have been finished by someone else.
  def handle_async({:onchain_step, hash}, result, socket),
    do: {:noreply, OnchainSteps.checked(socket, hash, result, &reread/2, &reread/2)}

  # Reading the launch

  defp read(socket) do
    auction = socket.assigns.auction

    socket
    |> assign(asked: true)
    |> start_async(:launch, fn -> FinishActions.read(auction) end)
  end

  defp reread(socket, _entry), do: read(socket)

  defp recheck_later(socket) do
    if socket.assigns.timer, do: Process.cancel_timer(socket.assigns.timer)

    timer =
      send_update_after(self(), __MODULE__, [id: socket.assigns.id, reread: true], @recheck_ms)

    assign(socket, timer: timer)
  end

  defp waiting?(%{state: :running, clock: clock, migration_block: migration_block}),
    do: clock < migration_block

  defp waiting?(_launch), do: false

  # The review for the wallet that may act, once the launch is read. A review
  # never changes, so the same signer and call keep the one on the page.
  defp reviewed(%{assigns: %{signer: signer, launch: %{chain: chain, call: call}}} = socket)
       when is_binary(signer) do
    review =
      Review.new(socket.assigns.id, signer, chain, [Review.step("finish", call.to, call.data)])

    OnchainSteps.put_review(socket, review)
  end

  defp reviewed(socket), do: OnchainSteps.put_review(socket, nil)

  # The step

  defp step(%{review: %{} = review, presses: presses}) do
    entry = OnchainSteps.entry(presses, review, "finish")
    %{name: "finish", label: "Finish auction", state: press_state(entry), entry: entry}
  end

  defp step(_assigns), do: nil

  # The button sends the finish while nothing is on its way, and again while it
  # is; before the review is on the page it still names the finish, and a
  # press says why nothing was sent.
  defp next_step(_step, blocked) when is_binary(blocked), do: nil
  defp next_step(nil, nil), do: %{name: "finish", label: "Finish auction"}
  defp next_step(%{state: state} = step, nil) when state in [:ready, :reverted, :other], do: step
  defp next_step(_step, nil), do: nil

  defp press_state(nil), do: :ready

  defp press_state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp press_state(%{outcome: :confirmed}), do: :done
  defp press_state(%{outcome: :reverted}), do: :reverted
  defp press_state(_not_this_step), do: :other

  # Why the finish is certain to fail now, from the chain's own reading.
  defp blocked(%{state: :running, clock: clock, migration_block: migration_block})
       when clock < migration_block,
       do: "Finishing opens at block #{migration_block}."

  defp blocked(%{state: :running}), do: nil

  defp blocked(%{state: _finished}),
    do: "This auction is finished. The page shows the result shortly."

  defp blocked(nil), do: nil

  defp progress(nil, _chain_name), do: nil

  defp progress(%{state: :sent}, _chain_name), do: "Finishing the auction…"

  defp progress(%{state: :stalled}, chain_name),
    do: "#{chain_name} has not confirmed this yet. Check again, or look in your wallet activity."

  defp progress(%{state: :other}, _chain_name),
    do:
      "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

  defp progress(%{state: :done}, _chain_name),
    do: "Finished. The page shows the result shortly."

  defp progress(_step, _chain_name), do: nil

  # One line, always in place, so nothing below it moves.
  defp line(blocked, _progress, _unread, _launch) when is_binary(blocked), do: blocked
  defp line(nil, progress, _unread, _launch) when is_binary(progress), do: progress
  defp line(nil, nil, true, _launch), do: "The auction could not be read just now."
  defp line(nil, nil, false, nil), do: "Reading the auction…"
  defp line(nil, nil, false, _launch), do: "Ready to finish."

  defp reverted(steps) do
    if Enum.any?(steps, &(&1.state == :reverted)),
      do: "That did not go through. Only the network fee was spent. Press again."
  end

  defp chain_name(%{launch: %{chain: %{name: name}}}), do: name

  defp chain_name(%{auction: %{chain_id: chain_id}}),
    do: Client.network_name(chain_id)
end
