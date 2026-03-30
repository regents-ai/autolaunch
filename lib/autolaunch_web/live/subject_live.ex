defmodule AutolaunchWeb.SubjectLive do
  use AutolaunchWeb, :live_view

  @poll_ms 15_000

  def mount(%{"id" => subject_id}, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)

    {:ok,
     socket
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

  def handle_event("prepare_stake", _params, socket) do
    {:noreply, prepare_action(socket, :stake, socket.assigns.stake_form)}
  end

  def handle_event("prepare_unstake", _params, socket) do
    {:noreply, prepare_action(socket, :unstake, socket.assigns.unstake_form)}
  end

  def handle_event("prepare_claim", _params, socket) do
    {:noreply, prepare_action(socket, :claim, %{})}
  end

  def handle_event("prepare_sweep", %{"address" => ingress_address}, socket) do
    {:noreply, prepare_action(socket, {:sweep, ingress_address}, %{})}
  end

  def handle_event("wallet_tx_started", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :info, message)}
  end

  def handle_event("wallet_tx_registered", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> assign(:pending_actions, %{})
     |> assign_subject(socket.assigns.subject_id)
     |> put_flash(:info, message)}
  end

  def handle_event("wallet_tx_error", %{"message" => message}, socket) do
    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_info(:refresh, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @poll_ms)
    {:noreply, assign_subject(socket, socket.assigns.subject_id)}
  end

  def render(assigns) do
    assigns = assign(assigns, :pending_actions, assigns.pending_actions || %{})

    ~H"""
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="subject-hero" class="al-hero al-panel" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Subject revenue</p>
          <h2>Stake, claim, and manage Sepolia revenue from one subject view.</h2>
          <p class="al-subcopy">
            This page tracks the revenue-share splitter, default ingress, and wallet-specific claim
            state for a launched agent token. Recognized revenue still means Sepolia USDC that has
            already reached the splitter. For launch lifecycle work like monitor, finalize, and vesting,
            the CLI is now the primary operator path.
          </p>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Subject" value={short_hash(@subject_id)} hint="Onchain subject id" />
          <.stat_card title="Wallet stake" value={@subject && (@subject.wallet_stake_balance || "0")} hint="Currently staked from this wallet" />
          <.stat_card title="Claimable USDC" value={@subject && (@subject.claimable_usdc || "0")} hint="Ready to claim now" />
          <.stat_card title="Total staked" value={@subject && @subject.total_staked} hint="Across all stakers" />
        </div>
      </section>

      <%= if @subject do %>
        <section id="subject-layout" class="al-subject-layout" phx-hook="MissionMotion">
          <article class="al-panel al-main-panel">
            <div class="al-section-head">
              <div>
                <p class="al-kicker">Subject state</p>
                <h3>Splitter, balances, and next actions</h3>
              </div>
            </div>

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
                <p>Sepolia USDC can be swept from ingress into the splitter.</p>
              </div>
              <div class="al-review-card">
                <span>Treasury residual</span>
                <strong>{@subject.treasury_residual_usdc}</strong>
                <p>Splitter-side treasury balance after staker allocation.</p>
              </div>
              <div class="al-review-card">
                <span>Protocol reserve</span>
                <strong>{@subject.protocol_reserve_usdc}</strong>
                <p>Protocol skim retained inside the splitter.</p>
              </div>
              <div class="al-review-card">
                <span>Wallet token balance</span>
                <strong>{@subject.wallet_token_balance || "0"}</strong>
                <p>Unstaked tokens available to move into the splitter.</p>
              </div>
            </div>

            <div class="al-action-row">
              <.link navigate={~p"/contracts?subject_id=#{@subject_id}"} class="al-ghost">
                Open advanced contracts console
              </.link>
            </div>

            <div class="al-note-grid">
              <article class="al-note-card">
                <p class="al-kicker">Stake</p>
                <strong>Move claimed tokens into the splitter.</strong>
                <p>Use the exact token amount you want this wallet to stake.</p>
                <form phx-change="stake_changed" class="al-inline-form">
                  <input type="text" name="stake[amount]" value={@stake_form["amount"]} placeholder="0.0" />
                </form>
                <div class="al-action-row">
                  <button
                    :if={!@pending_actions[:stake]}
                    type="button"
                    class="al-submit"
                    phx-click="prepare_stake"
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
                <p class="al-kicker">Unstake</p>
                <strong>Withdraw staked balance back to the same wallet.</strong>
                <p>The amount is denominated in the launch token, not USDC.</p>
                <form phx-change="unstake_changed" class="al-inline-form">
                  <input type="text" name="unstake[amount]" value={@unstake_form["amount"]} placeholder="0.0" />
                </form>
                <div class="al-action-row">
                  <button
                    :if={!@pending_actions[:unstake]}
                    type="button"
                    class="al-ghost"
                    phx-click="prepare_unstake"
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
                <p class="al-kicker">Claim</p>
                <strong>Withdraw recognized USDC to the connected wallet.</strong>
                <p>Claimable balance refreshes from onchain state after each confirmed transaction.</p>
                <div class="al-action-row">
                  <button
                    :if={!@pending_actions[:claim]}
                    type="button"
                    class="al-submit"
                    phx-click="prepare_claim"
                  >
                    Prepare USDC claim
                  </button>
                  <.wallet_tx_button
                    :if={@pending_actions[:claim]}
                    id="subject-claim"
                    class="al-submit"
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
                      phx-click="prepare_sweep"
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
          body="Check that the launch finished successfully and that this subject id exists in the current Sepolia launch stack."
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

  defp short_hash(nil), do: "pending"
  defp short_hash(value) when is_binary(value), do: "#{String.slice(value, 0, 10)}..."

  defp context_module do
    :autolaunch
    |> Application.get_env(:revenue_live, [])
    |> Keyword.get(:context_module, Autolaunch.Revenue)
  end
end
