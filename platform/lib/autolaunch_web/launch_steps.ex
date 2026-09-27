defmodule AutolaunchWeb.LaunchSteps do
  @moduledoc """
  What the three launch cards share (`AutolaunchWeb.LaunchWalletComponent`,
  `AutolaunchWeb.StocksLaunchWalletComponent` and
  `AutolaunchWeb.RobinhoodStocksLaunchComponent`): the wallet that may act, the
  one "Create the launch" step of the review on the page, and the lines and
  buttons under it.

  "Review launch" prepares the review on the server for Privy's active wallet
  when the signed-in account links it (`AutolaunchWeb.OnchainSteps`); with no
  active wallet it opens Privy's connect step instead. The review lives on the
  page. The step's button has no server round trip: the `OnchainSteps` hook
  sends it, every press reaches the wallet, and every outcome is the server's
  own read of the hash against the review it was sent from. A review nothing
  was sent from is dropped when another wallet becomes active.

  The lines above the button stay in the page and are only hidden, so one
  appearing never moves the button a person is pressing.
  """

  use Phoenix.Component

  import AutolaunchWeb.Components.StepState
  import Phoenix.LiveView, only: [start_async: 3]

  alias Autolaunch.LaunchReviews
  alias AutolaunchWeb.Components.SwapForm
  alias AutolaunchWeb.{OnchainSteps, Paths, Telemetry}
  alias RegentChain.{Presses, Review}

  @doc "The assigns a launch card starts with."
  def init(socket) do
    socket
    |> OnchainSteps.init()
    |> assign(signer: nil, mismatch: nil, prepared: nil, reviews: %{}, launched: nil, notice: nil)
  end

  @doc """
  Follows the wallet that may act. A review is built for one signer, so an
  unsent review for another one is dropped.
  """
  def followed(socket) do
    %{linked: linked, active: active, presses: presses, review: review} = socket.assigns
    signer = OnchainSteps.signer(linked, active)
    socket = assign(socket, signer: signer, mismatch: OnchainSteps.mismatch_note(linked, active))

    cond do
      is_nil(review) -> socket
      review.signer == signer -> socket
      started?(presses, review) -> socket
      true -> withdrawn(socket)
    end
  end

  @doc "Privy's active wallet as the page reported it."
  def activated(socket, params) do
    active = OnchainSteps.active_wallet(params)

    if active == socket.assigns.active,
      do: socket,
      else: socket |> assign(active: active, press_note: nil) |> followed()
  end

  @doc """
  "Review launch": `prepare` is called with the wallet that may act and answers
  `{:ok, prepared}` or `{:error, message}`. With no such wallet nothing is
  prepared: signed out the card says so, with no active wallet Privy's connect
  step opens, and with another wallet open the note beside the button names both.
  """
  def review(socket, prepare) do
    %{linked: linked, active: active, signer: signer} = socket.assigns

    cond do
      is_nil(linked) ->
        assign(socket, notice: "Sign in to launch from your wallet.")

      is_nil(active) ->
        socket |> assign(notice: nil) |> OnchainSteps.connect()

      is_nil(signer) ->
        assign(socket,
          notice: "Switch to a wallet on your account in your wallet app, then press again."
        )

      true ->
        case prepare.(signer) do
          {:ok, prepared} -> reviewed(socket, prepared)
          {:error, message} -> assign(socket, notice: message)
        end
    end
  end

  # The review on the page, and what each review was prepared with, so an
  # outcome is read against the launch it belongs to.
  defp reviewed(socket, prepared) do
    review = Review.new(socket.assigns.id, prepared.signer, prepared.chain, prepared.steps)
    send(self(), {:launch_review, :open})

    socket
    |> assign(
      prepared: prepared,
      notice: nil,
      press_note: nil,
      launched: nil,
      reviews: Map.put(socket.assigns.reviews, review.id, prepared)
    )
    |> OnchainSteps.put_review(review)
  end

  @doc "Takes the review off the page."
  def withdrawn(socket), do: socket |> assign(prepared: nil) |> OnchainSteps.put_review(nil)

  @doc "What the review a sent step came from was prepared with."
  def prepared(socket, %{review: %{id: id}}), do: Map.get(socket.assigns.reviews, id)

  @doc """
  Lists a confirmed launch sent from a saved Base review (`kind` as
  `Autolaunch.LaunchReviews` names it) at once, rather than when discovery
  next finds it. The answer arrives as `handle_async({:listed, hash}, ...)`.
  """
  def list(socket, kind, %{hash: hash} = entry) do
    case prepared(socket, entry) do
      %{action_id: action_id, chain: %{chain_id: chain_id}} ->
        start_async(socket, {:listed, hash}, fn ->
          {chain_id, LaunchReviews.confirm(kind, action_id, hash)}
        end)

      nil ->
        socket
    end
  end

  @doc "The launch `list/3` listed, with its auction page once the site has it."
  def listed(socket, {:ok, {chain_id, {:listed, _account_id, result}}}),
    do:
      assign(socket, launched: Map.put(result, "path", auction_path(chain_id, result["auction"])))

  def listed(socket, _not_yet),
    do:
      assign(socket,
        notice: "Your launch is confirmed. It appears on the site within a minute."
      )

  defp auction_path(chain_id, address) do
    case Autolaunch.get_auction_by_chain_address(chain_id, address,
           actor: %Autolaunch.Actors.System{},
           load: [:path_tail]
         ) do
      {:ok, %{} = auction} -> Paths.auction(auction)
      _unlisted -> nil
    end
  end

  @doc "A press that sent nothing, or may have sent something, in words for the person who pressed."
  def failed(socket, params, flow) do
    case Presses.failed(params) do
      {:ok, _name, reason} ->
        Telemetry.wallet_failed(flow, reason)
        %{linked: linked, active: active, review: review} = socket.assigns
        chain_name = review && review.chain.name
        assign(socket, press_note: OnchainSteps.failure_note(reason, linked, active, chain_name))

      :error ->
        socket
    end
  end

  @doc "The review's steps as the card shows them."
  def steps(%{review: %{} = review, presses: presses}) do
    Enum.map(review.steps, fn %{step: name} ->
      entry = OnchainSteps.entry(presses, review, name)
      %{name: name, label: "Create the launch", state: state(entry), entry: entry}
    end)
  end

  def steps(_assigns), do: []

  @doc "The digest of the exact bytes the launch step asks the wallet to sign."
  def digest(%{steps: [%{data: data}]}),
    do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc "Whether a step of `review` has been sent."
  def started?(presses, review),
    do: Enum.any?(review.steps, &OnchainSteps.entry(presses, review, &1.step))

  attr :steps, :list, required: true
  attr :review, :map, default: nil
  attr :mismatch, :string, default: nil
  attr :press_note, :string, default: nil
  attr :target, :any, required: true

  @doc """
  The review's progress, the wallet button and the buttons that close the
  review: "Cancel" while nothing is on its way, "Done" once the launch is
  confirmed.
  """
  def progress(assigns) do
    assigns =
      assign(assigns,
        next_step: Enum.find(assigns.steps, &(&1.state in [:ready, :reverted, :other])),
        chain_name: assigns.review && assigns.review.chain.name
      )

    ~H"""
    <%!-- The list styling drops list semantics, so the role is stated. --%>
    <ol class="launch-wallet-steps" role="list" aria-label="Launch progress">
      <li :for={step <- @steps} data-step={step.name}>
        <span>{step.label}</span>
        <.step_state state={chip(step)} />
        <span class="launch-wallet-mono" hidden={!step.entry}>
          {step.entry && RegentFormat.short_hash(step.entry.hash)}
        </span>
      </li>
    </ol>
    <p
      class="launch-wallet-settled"
      role="status"
      aria-live="polite"
      hidden={!progress_copy(@steps, @chain_name)}
    >
      {progress_copy(@steps, @chain_name)}
    </p>
    <p class="launch-wallet-notice" role="status" hidden={!@press_note}>{@press_note}</p>
    <SwapForm.wallet_step
      next_step={@next_step}
      steps={@steps}
      reverted={reverted(@steps)}
      signer={@review && @review.signer}
      chain_name={@chain_name}
      mismatch={@mismatch}
      check_event="check_again"
      target={@target}
    />
    <div class="launch-wallet-controls">
      <Regent.Primitives.button
        type="button"
        phx-click="cancel_review"
        phx-target={@target}
        variant="secondary"
        hidden={!cancellable?(@steps)}
      >
        Cancel
      </Regent.Primitives.button>
      <Regent.Primitives.button
        type="button"
        phx-click="clear_launch"
        phx-target={@target}
        variant="secondary"
        hidden={!finished?(@steps)}
      >
        Done
      </Regent.Primitives.button>
    </div>
    """
  end

  defp state(nil), do: :ready

  defp state(%{outcome: :pending} = entry),
    do: if(Presses.stalled?(entry), do: :stalled, else: :sent)

  defp state(%{outcome: :confirmed}), do: :done
  defp state(%{outcome: :reverted}), do: :reverted
  defp state(_not_this_step), do: :other

  defp chip(%{state: :ready}), do: "Ready"
  defp chip(%{state: state}) when state in [:sent, :stalled], do: "Sent"
  defp chip(%{state: :done}), do: "Confirmed"
  defp chip(%{state: :reverted}), do: "Reverted"
  defp chip(%{state: :other}), do: "Unresolved"

  defp finished?([]), do: false
  defp finished?(steps), do: Enum.all?(steps, &(&1.state == :done))

  defp cancellable?([]), do: false

  defp cancellable?(steps),
    do: not finished?(steps) and not Enum.any?(steps, &(&1.state in [:sent, :stalled]))

  defp progress_copy(steps, chain_name) do
    case Enum.find(steps, &(&1.state in [:sent, :stalled, :other])) do
      %{state: :other} ->
        "That transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

      %{state: :stalled} ->
        "#{chain_name} has not confirmed this yet. Check again, or look in your wallet activity."

      %{state: :sent} ->
        "Creating the launch…"

      nil ->
        nil
    end
  end

  defp reverted(steps) do
    if Enum.any?(steps, &(&1.state == :reverted)),
      do:
        "That launch did not go through, so nothing was created. Only the network fee was spent. Press again."
  end
end
