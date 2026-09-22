defmodule AutolaunchWeb.RobinhoodStocksLaunchComponent do
  @moduledoc """
  The wallet step of a memestock pair launch on Robinhood: one review, then the
  one launch transaction. There is no launch fee.

  The wallet Privy has selected drives everything here and its address is proved
  against the mounted lease before anything is read. Nothing is stored: the
  review lives on this page only, the browser reports a hash and stops, and
  every outcome on screen is the server's own read of that hash. A wallet's
  launches are the launchpad's own records.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Actors.Human
  alias Autolaunch.Robinhood.StocksLaunchActions

  @copy %{
    authentication_required: "Sign in to launch from your wallet.",
    session_unavailable: "Sign in again to continue.",
    session_lease_required: "Sign in again to continue.",
    wrong_signer:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    invalid_address:
      "Switch back to the wallet you signed in with, or sign out and sign in with this one.",
    chain_unavailable: "Robinhood could not be read just now. Try again in a moment.",
    invalid_chain_response: "Robinhood gave an incomplete answer. Try again in a moment.",
    robinhood_unavailable: "Robinhood launches are not open on this site.",
    launches_paused: "New launches are paused right now.",
    stock_not_admitted: "This stock is not open for launches right now. Choose another.",
    stock_invalid: "Choose a stock for this launch.",
    floor_price_missing: "Set a floor price on the draft first.",
    floor_price_too_low: "The floor price is too low to use. Raise it on the draft.",
    required_raise_missing: "Set a required raise on the draft first.",
    required_raise_invalid:
      "The required raise must be more than zero, in an amount this stock token can represent. Check it on the draft.",
    launch_metadata_incomplete: "This draft is missing something the launch needs.",
    launch_draft_not_found: "This draft is no longer available.",
    launch_draft_unavailable: "This draft could not be read just now.",
    envelope_invalid: "This review is out of date. Review the launch again.",
    invalid_hash: "That transaction could not be read. Check your wallet activity."
  }

  @generic "That did not go through. Try again in a moment."
  @unheld [:wrong_signer, :session_unavailable, :session_lease_required, :invalid_address]
  @steps %{"launch" => :launch}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:wallet, fn -> nil end)
     |> assign_new(:notice, fn -> nil end)
     |> assign_new(:review, fn -> nil end)
     |> assign_new(:sent, fn -> %{} end)
     |> assign_new(:launches, fn -> [] end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="launch-wallet" phx-hook="AutolaunchReviewedSteps" phx-target={@myself}>
      <p
        :if={@notice}
        class="launch-wallet-notice"
        role={if @notice.tone == :error, do: "alert", else: "status"}
      >
        {@notice.message}
      </p>

      <div :if={!@wallet} class="launch-wallet-empty">
        <p>Choose the wallet you want to launch from.</p>
        <Regent.Primitives.button type="button" data-wallet-connect>
          Connect or switch wallet
        </Regent.Primitives.button>
      </div>

      <div :if={@wallet && !@review} class="launch-wallet-open">
        <p class="launch-wallet-hint">
          Launching from {short(@wallet)}. Your wallet confirms every step.
        </p>
        <Regent.Primitives.button
          class="launch-wallet-primary"
          type="button"
          phx-click="review_launch"
          phx-target={@myself}
        >
          Review launch
        </Regent.Primitives.button>
      </div>

      <section
        :if={@wallet && @review}
        id={"#{@id}-review"}
        class="launch-wallet-review"
        aria-label="Launch review"
      >
        <h4>Review this launch</h4>
        <dl>
          <div>
            <dt>Token</dt>
            <dd>{argument(@review, "name")} · {argument(@review, "symbol")}</dd>
          </div>
          <div>
            <dt>Auction currency</dt>
            <dd>
              {argument(@review, "stock_symbol")}
              <span class="launch-wallet-mono">{argument(@review, "stock")}</span>
            </dd>
          </div>
          <div :for={[label, value] <- @review.review}>
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
          <div>
            <dt>Wallet</dt>
            <dd class="launch-wallet-mono">{short(@review.envelope["expected_signer"])}</dd>
          </div>
          <div>
            <dt>Network</dt>
            <dd>
              {network_name(@review.envelope["chain_id"])} · chain {@review.envelope["chain_id"]}
            </dd>
          </div>
          <div>
            <dt>Transactions</dt>
            <dd>One transaction</dd>
          </div>
        </dl>

        <p class="launch-wallet-risk">{@review.envelope["risk_copy"]}</p>

        <ol class="launch-wallet-steps" role="list" aria-label="Launch progress">
          <li :for={step <- @review.steps} data-step={step["step"]}>
            <span>{step_label(step["step"])}</span>
            <span class="launch-wallet-step-state">{step_state(@sent[step["step"]])}</span>
            <span
              :if={@sent[step["step"]]}
              class="launch-wallet-mono"
              data-local-transaction-hash
            >
              {short_hash(@sent[step["step"]].hash)}
            </span>
          </li>
        </ol>

        <section :if={launched(@sent)} class="launch-wallet-settled" role="status">
          <p>
            The launch was created and its record was verified.
            <span :if={@review.envelope["chain_id"] == 31_338}>Test assets have no real value.</span>
          </p>
          <p>
            Launch #{launched(@sent)["launch_id"]} · Token
            <span class="launch-wallet-mono">{launched(@sent)["new_token"]}</span>
            · Auction <span class="launch-wallet-mono">{launched(@sent)["auction"]}</span>
          </p>
          <p>
            Bidding opens at block {launched(@sent)["start_block"]} and ends at block {launched(@sent)[
              "end_block"
            ]}.
          </p>
          <p>
            <.link navigate={~p"/robinhood/auctions/#{launched(@sent)["auction"]}"}>
              Open the auction page
            </.link>
          </p>
        </section>

        <Regent.Primitives.disclosure
          id={"#{@id}-terms"}
          summary="Fixed terms"
          class="launch-wallet-details"
        >
          <dl>
            <div :for={[label, value] <- argument(@review, "terms")}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
          </dl>
        </Regent.Primitives.disclosure>

        <Regent.Primitives.disclosure
          id={"#{@id}-exact-values"}
          summary="Exact values"
          class="launch-wallet-details"
        >
          <dl>
            <div :for={{label, value} <- exact_values(@review)}>
              <dt>{label}</dt>
              <dd class="launch-wallet-mono">{value}</dd>
            </div>
          </dl>
        </Regent.Primitives.disclosure>

        <div class="launch-wallet-controls">
          <Regent.Primitives.button
            :for={step <- @review.steps}
            :if={!launched(@sent)}
            type="button"
            data-reviewed-step={step["step"]}
            variant={
              if step["step"] == next_step(@review.steps, @sent), do: "primary", else: "secondary"
            }
          >
            {step_label(step["step"])}
          </Regent.Primitives.button>
          <Regent.Primitives.button
            :for={{name, %{outcome: :pending}} <- @sent}
            type="button"
            phx-click="check_step"
            phx-value-step={name}
            phx-target={@myself}
            variant="secondary"
          >
            Check again
          </Regent.Primitives.button>
          <Regent.Primitives.button
            type="button"
            phx-click="clear_review"
            phx-target={@myself}
            variant="secondary"
          >
            {if launched(@sent), do: "Done", else: "Start over"}
          </Regent.Primitives.button>
        </div>
      </section>

      <section :if={@launches != []} class="launch-wallet-settled" aria-label="Your launches">
        <h4>Your Robinhood launches</h4>
        <ul role="list">
          <li :for={launch <- @launches}>
            Launch #{launch["launch_id"]} · {lifecycle(launch["lifecycle"])} ·
            <.link navigate={~p"/robinhood/auctions/#{launch["auction"]}"}>
              Auction <span class="launch-wallet-mono">{launch["auction"]}</span>
            </.link>
          </li>
        </ul>
      </section>
    </section>
    """
  end

  @impl true
  def handle_event("active_wallet", %{"address" => address}, socket),
    do: {:noreply, adopt(socket, address)}

  def handle_event("review_launch", _params, socket) do
    case StocksLaunchActions.prepare(socket.assigns.draft.id, socket.assigns.wallet, opts(socket)) do
      {:ok, review} ->
        {:noreply, socket |> assign(review: review, sent: %{}, notice: nil) |> published()}

      {:error, error} ->
        {:noreply, assign(socket, notice: notice(:error, refusal(error)))}
    end
  end

  def handle_event("step_sent", %{"step" => name, "transaction_hash" => hash}, socket)
      when is_map_key(@steps, name) and is_binary(hash),
      do: {:noreply, checked(socket, name, hash)}

  def handle_event("check_step", %{"step" => name}, socket) do
    case socket.assigns.sent[name] do
      %{hash: hash} -> {:noreply, checked(socket, name, hash)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("step_failed", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, notice: %{tone: :error, message: wallet_failure_copy(reason)})}

  def handle_event("clear_review", _params, socket) do
    {:noreply,
     socket
     |> assign(review: nil, sent: %{}, notice: nil)
     |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})}
  end

  def handle_event(_other, _params, socket), do: {:noreply, socket}

  # The server reads the reported hash itself; the browser's word is only the hash.
  defp checked(%{assigns: %{review: %{envelope: envelope}}} = socket, name, hash) do
    case StocksLaunchActions.verify(envelope, Map.fetch!(@steps, name), hash, opts(socket)) do
      {:ok, %{outcome: outcome} = read} ->
        entry = %{hash: hash, outcome: outcome, result: Map.get(read, :result)}

        socket
        |> assign(
          sent: Map.put(socket.assigns.sent, name, entry),
          notice: outcome_notice(outcome)
        )
        |> listed(outcome)

      {:error, error} ->
        assign(socket, notice: notice(:error, refusal(error)))
    end
  end

  defp checked(socket, _name, _hash), do: socket

  defp listed(socket, :confirmed), do: with_launches(socket)
  defp listed(socket, _outcome), do: socket

  defp published(%{assigns: %{review: %{envelope: envelope, steps: steps}}} = socket) do
    push_event(socket, "reviewed-steps:review", %{
      component_id: socket.assigns.id,
      signer: envelope["expected_signer"],
      chain_id: envelope["chain_id"],
      lab: envelope["metadata"]["lab"],
      lab_anchor: %{
        block_number: envelope["arguments"]["block_number"],
        block_hash: envelope["arguments"]["block_hash"]
      },
      steps: Enum.map(steps, &Map.take(&1, ["step", "to", "data"]))
    })
  end

  defp adopt(socket, nil), do: assign(socket, wallet: nil, notice: nil)

  defp adopt(%{assigns: %{wallet: wallet}} = socket, wallet), do: socket

  defp adopt(socket, address) do
    case StocksLaunchActions.launches(address, opts(socket)) do
      {:ok, %{launches: launches}} ->
        socket
        |> assign(wallet: String.downcase(address), launches: launches, notice: nil)
        |> reviewed_for_wallet()

      {:error, error} ->
        refused(socket, address, refusal(error))
    end
  end

  # A review belongs to the wallet it was prepared for; another wallet starts clean.
  defp reviewed_for_wallet(%{assigns: %{review: %{envelope: envelope}, wallet: wallet}} = socket) do
    if String.downcase(envelope["expected_signer"]) == wallet,
      do: socket,
      else:
        socket
        |> assign(review: nil, sent: %{})
        |> push_event("reviewed-steps:cleared", %{component_id: socket.assigns.id})
  end

  defp reviewed_for_wallet(socket), do: socket

  defp with_launches(socket) do
    case StocksLaunchActions.launches(socket.assigns.wallet, opts(socket)) do
      {:ok, %{launches: launches}} -> assign(socket, launches: launches)
      {:error, _unavailable} -> socket
    end
  end

  # Any wallet but the signed-in one is not adopted at all; the signed-in one
  # stays on screen with the reason.
  defp refused(socket, _address, reason) when reason in @unheld,
    do: assign(socket, wallet: nil, review: nil, sent: %{}, notice: notice(:error, reason))

  defp refused(socket, address, reason),
    do: assign(socket, wallet: String.downcase(address), notice: notice(:info, reason))

  defp opts(socket),
    do: [actor: actor(socket), context: %{session_lease: socket.assigns.session_lease}]

  defp actor(%{assigns: %{current_human_id: id}}) when is_integer(id),
    do: %Human{human_account_id: id}

  defp actor(_socket), do: nil

  defp launched(sent) do
    case sent["launch"] do
      %{outcome: :confirmed, result: result} -> result
      _other -> nil
    end
  end

  defp next_step(steps, sent) do
    Enum.find_value(steps, fn %{"step" => name} ->
      if match?(%{outcome: :confirmed}, sent[name]), do: nil, else: name
    end)
  end

  defp network_name(31_338), do: "Robinhood test network"
  defp network_name(_chain_id), do: "Robinhood Chain"

  defp step_label("launch"), do: "Create the launch"

  defp step_state(nil), do: "Ready"
  defp step_state(%{outcome: :pending}), do: "Sent"
  defp step_state(%{outcome: :confirmed}), do: "Verified"
  defp step_state(%{outcome: :reverted}), do: "Reverted"
  defp step_state(%{outcome: :unverified}), do: "Unresolved"

  defp outcome_notice(:pending),
    do: %{tone: :info, message: "Sent. Waiting for Robinhood to include it."}

  defp outcome_notice(:confirmed), do: nil

  defp outcome_notice(:reverted),
    do: %{tone: :error, message: "That transaction reverted. Nothing was created."}

  defp outcome_notice(:unverified),
    do: %{tone: :error, message: "That transaction did not record the step you reviewed."}

  defp lifecycle("active"), do: "Active"
  defp lifecycle("graduated"), do: "Graduated"
  defp lifecycle("failed"), do: "Required raise not reached"
  defp lifecycle("none"), do: "Not started"

  defp exact_values(review) do
    [
      {"Launchpad", argument(review, "launchpad")},
      {"Stock route", argument(review, "route")},
      {"Stock decimals", argument(review, "stock_decimals")},
      {"Required raise (stock base units)", argument(review, "required_stock_raised")},
      {"Floor price (Q96)", argument(review, "floor_price_q96")},
      {"Bid tick spacing (Q96)", argument(review, "tick_spacing_q96")},
      {"Bidding opens (blocks after creation)", argument(review, "start_lead_blocks")},
      {"Auction length (blocks)", argument(review, "auction_duration_blocks")},
      {"Reviewed block",
       "#{argument(review, "block_number")} · #{argument(review, "block_hash")}"},
      {"Calldata digest", review.envelope["metadata"]["calldata_sha256"]}
    ]
  end

  defp wallet_failure_copy("wallet_unavailable"),
    do: "Open the wallet you signed in with, then try again. Nothing was sent."

  defp wallet_failure_copy("network_mismatch"),
    do:
      "Your wallet is connected to a different network under the reviewed chain number. Check the network settings in your wallet, then try again. Nothing was sent."

  defp wallet_failure_copy("wallet_declined"), do: "Your wallet declined this. Nothing was sent."

  defp wallet_failure_copy("send_unconfirmed"),
    do: "Your wallet may have sent this transaction. Check your wallet activity."

  defp wallet_failure_copy(_unknown), do: @generic

  defp notice(tone, reason), do: %{tone: tone, message: Map.get(@copy, reason, @generic)}

  defp refusal(%{errors: errors}), do: Enum.find_value(errors, :unavailable, &unavailable/1)
  defp refusal(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp refusal(reason) when is_atom(reason), do: reason
  defp refusal(_other), do: :unavailable

  defp unavailable(%Ash.Error.Invalid.Unavailable{reason: reason}), do: reason
  defp unavailable(_other), do: nil

  defp argument(%{envelope: envelope}, key), do: envelope["arguments"][key]

  defp short("0x" <> address),
    do: "0x#{String.slice(address, 0, 4)}…#{String.slice(address, -4, 4)}"

  defp short_hash("0x" <> hash),
    do: "0x#{String.slice(hash, 0, 6)}…#{String.slice(hash, -4, 4)}"
end
