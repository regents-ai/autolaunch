defmodule AutolaunchWeb.SubjectLive do
  use AutolaunchWeb, :live_view

  alias AutolaunchWeb.Live.Refreshable

  @poll_ms 15_000

  def mount(%{"id" => subject_id}, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> assign(:page_title, "Subject Revenue")
     |> assign(:active_view, "subjects")
     |> assign(:subject_id, subject_id)
     |> assign(:stake_form, %{"amount" => ""})
     |> assign(:unstake_form, %{"amount" => ""})
     |> assign(:pending_actions, %{})
     |> assign_subject(subject_id)}
  end

  def handle_event("stake_changed", %{"stake" => attrs}, socket) do
    {:noreply, assign(socket, :stake_form, Map.merge(socket.assigns.stake_form, attrs))}
  end

  def handle_event("unstake_changed", %{"unstake" => attrs}, socket) do
    {:noreply, assign(socket, :unstake_form, Map.merge(socket.assigns.unstake_form, attrs))}
  end

  def handle_event(
        "prepare_action",
        %{"action" => "sweep", "address" => ingress_address},
        socket
      ) do
    {:noreply, prepare_action(socket, {:sweep, ingress_address}, %{})}
  end

  def handle_event("prepare_action", %{"action" => "stake"}, socket) do
    {:noreply, prepare_action(socket, :stake, socket.assigns.stake_form)}
  end

  def handle_event("prepare_action", %{"action" => "unstake"}, socket) do
    {:noreply, prepare_action(socket, :unstake, socket.assigns.unstake_form)}
  end

  def handle_event("prepare_action", %{"action" => action}, socket) do
    {:noreply, prepare_action(socket, action_to_atom(action), %{})}
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_started(socket, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_registered(socket, message, &reload_subject/1)}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, Refreshable.wallet_error(socket, message)}
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &reload_subject/1)}
  end

  def render(assigns) do
    subject = assigns.subject
    recommended = recommended_action(subject)
    wallet_position = wallet_position(subject)

    assigns =
      assigns
      |> assign(:pending_actions, assigns.pending_actions || %{})
      |> assign(:recommended_action, recommended)
      |> assign(:wallet_position, wallet_position)

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="subject-hero" class="al-hero al-panel" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Subject revenue</p>
          <h2>See the revenue state, then take the one action that matters most.</h2>
          <p class="al-subcopy">
            Recognized revenue still means Base USDC that has already reached the splitter. This
            page stays focused on what the connected wallet can claim, stake, unstake, or sweep now.
          </p>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Claimable USDC" value={@wallet_position.claimable_usdc} hint="Ready now" />
          <.stat_card
            title="Your staked tokens"
            value={@wallet_position.wallet_stake_balance}
            hint="Currently staked from this wallet"
          />
          <.stat_card
            title="Wallet token balance"
            value={@wallet_position.wallet_token_balance}
            hint="Still available to stake"
          />
          <.stat_card
            title="Claimable emissions"
            value={@wallet_position.claimable_stake_token}
            hint="Reward tokens ready to claim or restake"
          />
        </div>
      </section>

      <%= if @subject do %>
        <section id="subject-layout" class="al-subject-layout" phx-hook="MissionMotion">
          <article class="al-panel al-main-panel">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Primary next step</p>
                <h3>{recommended_action_heading(@recommended_action)}</h3>
              </div>
            </div>

            <section id="subject-primary-actions" class="al-subject-action-group" phx-hook="MissionMotion">
              <div class="al-inline-banner">
                <strong>Start with the action cards.</strong>
                <p>
                  Claim, stake, unstake, or sweep from this area first. Open the subject details
                  only when you need addresses, balances, or the advanced contract console.
                </p>
              </div>

              <div class="al-note-grid">
              <article class="al-note-card">
                <p class="al-kicker">Stake</p>
                <strong>Move claimed tokens into the splitter.</strong>
                <p>{@wallet_position.stake_note}</p>
                <p>Use the exact token amount you want this wallet to stake.</p>
                <form phx-change="stake_changed" class="al-inline-form">
                  <label class="al-kicker" for="subject-stake-amount">Amount</label>
                  <input
                    id="subject-stake-amount"
                    type="text"
                    inputmode="decimal"
                    name="stake[amount]"
                    value={@stake_form["amount"]}
                    placeholder="0.0"
                  />
                </form>
                <div class="al-action-row">
                  <button
                    :if={!@pending_actions[:stake]}
                    type="button"
                    class="al-submit"
                    phx-click="prepare_action"
                    phx-value-action="stake"
                  >
                    Prepare stake
                  </button>
                  <.wallet_tx_button
                    :if={@pending_actions[:stake]}
                    id="subject-stake"
                    class="al-submit"
                    tx_request={@pending_actions[:stake].tx_request}
                    register_endpoint={~p"/api/subjects/#{@subject_id}/stake"}
                    register_body={%{"amount" => @stake_form["amount"]}}
                    pending_message="Stake transaction sent. Waiting for confirmation."
                    success_message="Stake registered."
                  >
                    Send stake transaction
                  </.wallet_tx_button>
                </div>
              </article>

              <article class="al-note-card">
                <p class="al-kicker">Claim</p>
                <strong>Withdraw recognized USDC to the connected wallet.</strong>
                <p>{@wallet_position.claim_note}</p>
                <p>Claimable balance refreshes from onchain state after each confirmed transaction.</p>
                <div class="al-action-row">
                  <button
                    :if={!@pending_actions[:claim]}
                    type="button"
                    class={subject_action_class(@recommended_action, :claim)}
                    phx-click="prepare_action"
                    phx-value-action="claim"
                  >
                    Prepare USDC claim
                  </button>
                  <.wallet_tx_button
                    :if={@pending_actions[:claim]}
                    id="subject-claim"
                    class={subject_action_class(@recommended_action, :claim)}
                    tx_request={@pending_actions[:claim].tx_request}
                    register_endpoint={~p"/api/subjects/#{@subject_id}/claim-usdc"}
                    register_body={%{}}
                    pending_message="Claim transaction sent. Waiting for confirmation."
                    success_message="USDC claim registered."
                  >
                    Send claim transaction
                  </.wallet_tx_button>
                </div>
              </article>
              </div>
            </section>

            <details id="subject-secondary-actions" class="al-panel al-disclosure" phx-hook="MissionMotion">
              <summary class="al-disclosure-summary">
                <div>
                  <p class="al-kicker">Other actions</p>
                  <h3>Unstake, emissions, and ingress tools</h3>
                </div>
                <span class="al-network-badge">Secondary</span>
              </summary>

              <div class="al-note-grid">
                <article class="al-note-card">
                  <p class="al-kicker">Unstake</p>
                  <strong>Withdraw staked balance back to the same wallet.</strong>
                  <p>{@wallet_position.unstake_note}</p>
                  <p>The amount is denominated in the launch token, not USDC.</p>
                  <form phx-change="unstake_changed" class="al-inline-form">
                    <label class="al-kicker" for="subject-unstake-amount">Amount</label>
                    <input
                      id="subject-unstake-amount"
                      type="text"
                      inputmode="decimal"
                      name="unstake[amount]"
                      value={@unstake_form["amount"]}
                      placeholder="0.0"
                    />
                  </form>
                  <div class="al-action-row">
                    <button
                      :if={!@pending_actions[:unstake]}
                      type="button"
                      class="al-ghost"
                      phx-click="prepare_action"
                      phx-value-action="unstake"
                    >
                      Prepare unstake
                    </button>
                    <.wallet_tx_button
                      :if={@pending_actions[:unstake]}
                      id="subject-unstake"
                      class="al-ghost"
                      tx_request={@pending_actions[:unstake].tx_request}
                      register_endpoint={~p"/api/subjects/#{@subject_id}/unstake"}
                      register_body={%{"amount" => @unstake_form["amount"]}}
                      pending_message="Unstake transaction sent. Waiting for confirmation."
                      success_message="Unstake registered."
                    >
                      Send unstake transaction
                    </.wallet_tx_button>
                  </div>
                </article>

                <article class="al-note-card">
                  <p class="al-kicker">Emissions</p>
                  <strong>Claim reward tokens or claim and restake them in one move.</strong>
                  <p>{@wallet_position.emissions_note}</p>
                  <div class="al-action-row">
                    <button
                      :if={!@pending_actions[:claim_emissions]}
                      type="button"
                      class="al-ghost"
                      phx-click="prepare_action"
                      phx-value-action="claim_emissions"
                    >
                      Prepare emissions claim
                    </button>
                    <.wallet_tx_button
                      :if={@pending_actions[:claim_emissions]}
                      id="subject-claim-emissions"
                      class="al-ghost"
                      tx_request={@pending_actions[:claim_emissions].tx_request}
                      register_endpoint={~p"/api/subjects/#{@subject_id}/claim-emissions"}
                      register_body={%{}}
                      pending_message="Emission claim sent. Waiting for confirmation."
                      success_message="Emission claim registered."
                    >
                      Send emissions claim
                    </.wallet_tx_button>

                    <button
                      :if={!@pending_actions[:claim_and_stake_emissions]}
                      type="button"
                      class="al-submit al-submit--secondary"
                      phx-click="prepare_action"
                      phx-value-action="claim_and_stake_emissions"
                    >
                      Prepare claim and stake
                    </button>
                    <.wallet_tx_button
                      :if={@pending_actions[:claim_and_stake_emissions]}
                      id="subject-claim-and-stake-emissions"
                      class="al-submit al-submit--secondary"
                      tx_request={@pending_actions[:claim_and_stake_emissions].tx_request}
                      register_endpoint={~p"/api/subjects/#{@subject_id}/claim-and-stake-emissions"}
                      register_body={%{}}
                      pending_message="Claim and stake sent. Waiting for confirmation."
                      success_message="Emission claim and stake registered."
                    >
                      Send claim and stake
                    </.wallet_tx_button>
                  </div>
                </article>
              </div>
            </details>

            <details
              id="subject-state-details"
              class="al-panel al-disclosure"
              phx-hook="MissionMotion"
            >
              <summary class="al-disclosure-summary">
                <div>
                  <p class="al-kicker">Subject state</p>
                  <h3>Balances, addresses, and advanced review</h3>
                </div>
                <span class="al-network-badge">Details</span>
              </summary>

              <div class="al-review-grid">
                <div class="al-review-card">
                  <span>Token</span>
                  <strong>{short_address(@subject.token_address)}</strong>
                  <p>Staking token for this subject.</p>
                </div>
                <div class="al-review-card">
                  <span>Splitter</span>
                  <strong>{short_address(@subject.splitter_address)}</strong>
                  <p>Recognized revenue lands here before claims.</p>
                </div>
                <div class="al-review-card">
                  <span>Default ingress</span>
                  <strong>{short_address(@subject.default_ingress_address)}</strong>
                  <p>Base USDC can be swept from ingress into the splitter.</p>
                </div>
                <div class="al-review-card">
                  <span>Treasury residual</span>
                  <strong>{@subject.treasury_residual_usdc}</strong>
                  <p>Splitter-side treasury balance after staker allocation.</p>
                </div>
                <div class="al-review-card">
                  <span>Wallet position</span>
                  <strong>Claim, stake, or unstake from here</strong>
                  <p>{@wallet_position.summary}</p>
                  <p>{@wallet_position.staked_line}</p>
                  <p>{@wallet_position.wallet_line}</p>
                  <p>{@wallet_position.claimable_usdc_line}</p>
                  <p>{@wallet_position.claimable_emissions_line}</p>
                </div>
                <div class="al-review-card">
                  <span>Protocol reserve</span>
                  <strong>{@subject.protocol_reserve_usdc}</strong>
                  <p>Protocol skim retained inside the splitter.</p>
                </div>
              </div>

              <div class="al-action-row">
                <.link navigate={~p"/contracts?subject_id=#{@subject_id}"} class="al-ghost">
                  Open advanced contracts console
                </.link>
              </div>
            </details>
          </article>

          <aside class="al-panel al-side-panel">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Ingress</p>
                <h3>Known USDC intake accounts</h3>
              </div>
            </div>

            <%= if @subject.ingress_accounts == [] do %>
              <p class="al-inline-note">No ingress accounts are currently available for this subject.</p>
            <% else %>
              <div class="al-subject-ingress-list">
                <article
                  :for={ingress <- @subject.ingress_accounts}
                  class="al-note-card al-ingress-card"
                >
                  <p class="al-kicker">{if ingress.is_default, do: "Default ingress", else: "Ingress account"}</p>
                  <strong>{short_address(ingress.address)}</strong>
                  <p>USDC balance: {ingress.usdc_balance}</p>
                  <div class="al-action-row">
                    <button
                      :if={@subject.can_manage_ingress and !@pending_actions[{:sweep, ingress.address}]}
                      type="button"
                      class="al-ghost"
                      phx-click="prepare_action"
                      phx-value-action="sweep"
                      phx-value-address={ingress.address}
                    >
                      Prepare sweep
                    </button>
                    <.wallet_tx_button
                      :if={@pending_actions[{:sweep, ingress.address}]}
                      id={"subject-sweep-#{ingress.address}"}
                      class="al-ghost"
                      tx_request={@pending_actions[{:sweep, ingress.address}].tx_request}
                      register_endpoint={~p"/api/subjects/#{@subject_id}/ingress/#{ingress.address}/sweep"}
                      register_body={%{}}
                      pending_message="Sweep transaction sent. Waiting for confirmation."
                      success_message="Ingress sweep registered."
                    >
                      Send sweep transaction
                    </.wallet_tx_button>
                  </div>
                </article>
              </div>
            <% end %>
          </aside>
        </section>
      <% else %>
        <.empty_state
          title="Subject state is unavailable."
          body="Check that the launch finished successfully and that this subject id exists in the current launch stack."
        />
      <% end %>

      <.flash_group flash={@flash} />
    </.shell>
    """
  end

  defp assign_subject(socket, subject_id) do
    case context_module().get_subject(subject_id, socket.assigns[:current_human]) do
      {:ok, subject} -> assign(socket, :subject, subject)
      _ -> assign(socket, :subject, nil)
    end
  end

  defp reload_subject(socket) do
    socket
    |> assign(:pending_actions, %{})
    |> assign_subject(socket.assigns.subject_id)
  end

  defp prepare_action(socket, action, attrs) do
    subject_id = socket.assigns.subject_id
    current_human = socket.assigns.current_human

    result =
      case action do
        :stake ->
          context_module().stake(subject_id, attrs, current_human)

        :unstake ->
          context_module().unstake(subject_id, attrs, current_human)

        :claim ->
          context_module().claim_usdc(subject_id, attrs, current_human)

        :claim_emissions ->
          context_module().claim_emissions(subject_id, attrs, current_human)

        :claim_and_stake_emissions ->
          context_module().claim_and_stake_emissions(subject_id, attrs, current_human)

        {:sweep, ingress_address} ->
          context_module().sweep_ingress(subject_id, ingress_address, attrs, current_human)
      end

    case result do
      {:ok, %{tx_request: tx_request, subject: subject}} ->
        socket
        |> assign(:subject, subject)
        |> put_pending_action(action, tx_request)

      {:error, :unauthorized} ->
        put_flash(socket, :error, "Privy session required before this wallet action.")

      {:error, :forbidden} ->
        put_flash(socket, :error, "This wallet cannot perform that subject action.")

      {:error, :amount_required} ->
        put_flash(socket, :error, "Enter an amount before preparing the wallet transaction.")

      {:error, _} ->
        put_flash(socket, :error, "Unable to prepare the wallet transaction right now.")
    end
  end

  defp put_pending_action(socket, action, tx_request) do
    assign(
      socket,
      :pending_actions,
      Map.put(socket.assigns.pending_actions, action, %{tx_request: tx_request})
    )
  end

  defp short_address(nil), do: "pending"

  defp short_address(address) when is_binary(address) do
    prefix = String.slice(address, 0, 6)
    suffix = String.slice(address, -4, 4)
    "#{prefix}...#{suffix}"
  end

  defp context_module do
    :autolaunch
    |> Application.get_env(:revenue_live, [])
    |> Keyword.get(:context_module, Autolaunch.Revenue)
  end

  defp subject_value(nil, _key), do: "0"
  defp subject_value(subject, key) when is_map(subject), do: Map.get(subject, key, "0")

  defp wallet_position(subject) do
    staked = subject_value(subject, :wallet_stake_balance)
    wallet = subject_value(subject, :wallet_token_balance)
    claimable_usdc = subject_value(subject, :claimable_usdc)
    claimable_emissions = subject_value(subject, :claimable_stake_token)

    %{
      wallet_stake_balance: staked,
      wallet_token_balance: wallet,
      claimable_usdc: claimable_usdc,
      claimable_stake_token: claimable_emissions,
      summary:
        "Your staked balance, wallet balance, claimable USDC, and claimable emissions all live here.",
      staked_line: "Staked: #{staked}",
      wallet_line: "Wallet: #{wallet}",
      claimable_usdc_line: "USDC: #{claimable_usdc}",
      claimable_emissions_line: "Emissions: #{claimable_emissions}",
      stake_note: "Wallet balance: #{wallet}.",
      unstake_note: "Currently staked: #{staked}.",
      claim_note: "Claimable now: #{claimable_usdc}.",
      emissions_note: "Claimable emissions: #{claimable_emissions}."
    }
  end

  defp recommended_action(nil), do: nil

  defp recommended_action(subject) do
    cond do
      positive_amount?(Map.get(subject, :claimable_usdc)) -> :claim
      positive_amount?(Map.get(subject, :wallet_token_balance)) -> :stake
      positive_amount?(Map.get(subject, :wallet_stake_balance)) -> :unstake
      positive_amount?(Map.get(subject, :claimable_stake_token)) -> :claim_and_stake_emissions
      true -> nil
    end
  end

  defp recommended_action_heading(:claim), do: "Claim the recognized USDC first"
  defp recommended_action_heading(:stake), do: "Stake the idle wallet balance next"
  defp recommended_action_heading(:unstake), do: "Unstake if you need the wallet balance back"

  defp recommended_action_heading(:claim_and_stake_emissions),
    do: "Roll emissions back into stake"

  defp recommended_action_heading(_), do: "No urgent wallet action detected"

  defp subject_action_class(recommended, action) do
    if recommended == action, do: "al-submit", else: "al-submit al-submit--secondary"
  end

  defp positive_amount?(nil), do: false

  defp positive_amount?(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.compare(decimal, Decimal.new(0)) == :gt
      _ -> false
    end
  end

  defp action_to_atom("stake"), do: :stake
  defp action_to_atom("unstake"), do: :unstake
  defp action_to_atom("claim"), do: :claim
  defp action_to_atom("claim_emissions"), do: :claim_emissions
  defp action_to_atom("claim_and_stake_emissions"), do: :claim_and_stake_emissions
  defp action_to_atom(_), do: :claim
end
