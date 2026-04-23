defmodule AutolaunchWeb.ContractsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Contracts
  alias AutolaunchWeb.Live.Refreshable

  @route_css_path Path.expand("../../../priv/static/launch-docs-live.css", __DIR__)
  @external_resource @route_css_path
  @route_css File.read!(@route_css_path)

  @poll_ms 15_000

  def mount(params, _session, socket) do
    {:ok,
     socket
     |> Refreshable.schedule(@poll_ms)
     |> assign(:page_title, "Contracts")
     |> assign(:active_view, "contracts")
     |> assign(:job_id, Map.get(params, "job_id"))
     |> assign(:subject_id, Map.get(params, "subject_id"))
     |> assign(:job_scope, nil)
     |> assign(:settlement_summary, nil)
     |> assign(:subject_scope, nil)
     |> assign(:admin_scope, nil)
     |> assign(:wallet_switch, nil)
     |> assign(:forms, default_forms())
     |> assign(:prepared, nil)
     |> load_console()}
  end

  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:job_id, blank_to_nil(Map.get(params, "job_id")))
     |> assign(:subject_id, blank_to_nil(Map.get(params, "subject_id")))
     |> load_console()}
  end

  def handle_event("update_form", %{"form_name" => form_name, "form" => attrs}, socket) do
    {:noreply, assign(socket, :forms, Map.put(socket.assigns.forms, form_name, attrs))}
  end

  def handle_event(
        "prepare_action",
        %{"scope" => scope, "resource" => resource, "action" => action, "form_name" => form_name},
        socket
      ) do
    attrs = Map.get(socket.assigns.forms, form_name, %{})

    result =
      case scope do
        "job" ->
          context_module().prepare_job_action(
            socket.assigns.job_id,
            resource,
            action,
            attrs,
            socket.assigns.current_human
          )

        "subject" ->
          context_module().prepare_subject_action(
            socket.assigns.subject_id,
            resource,
            action,
            attrs,
            socket.assigns.current_human
          )

        "admin" ->
          context_module().prepare_admin_action(resource, action, attrs)
      end

    case result do
      {:ok, %{job_id: _job_id, prepared: prepared}} ->
        {:noreply, assign(socket, :prepared, prepared)}

      {:ok, %{subject_id: _subject_id, prepared: prepared}} ->
        {:noreply, assign(socket, :prepared, prepared)}

      {:ok, %{prepared: prepared}} ->
        {:noreply, assign(socket, :prepared, prepared)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "This wallet cannot prepare that contract action.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, prepare_error(reason))}
    end
  end

  def handle_info(:refresh, socket) do
    {:noreply, Refreshable.refresh(socket, @poll_ms, &load_console/1)}
  end

  def render(assigns) do
    ~H"""
    <style><%= Phoenix.HTML.raw(route_css()) %></style>
    <.shell
      current_human={@current_human}
      active_view={@active_view}
      wallet_switch={@wallet_switch}
    >
      <div id="al-docs-page" data-docs-page="contracts">
      <AutolaunchWeb.DocsFamilyComponents.header
        active="contracts"
        title="Review the contract view you need before you prepare anything."
        body="Open one launch job, one token subject, or the shared admin view. Keep the read side close so you can confirm the next approved action before anything is signed."
      />

      <section id="contracts-hero" class="al-hero al-panel al-contracts-hero" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Contracts</p>
          <h2>Pick the contract view you need before you review or prepare anything.</h2>
          <p class="al-subcopy">
            Start with a launch job, a subject id, or the shared admin view. This page keeps
            review first and preparation second.
          </p>

          <div class="al-contract-pill-row">
            <span class="al-launch-tag">Review before you sign</span>
            <span class="al-launch-tag">Open from launch and token pages</span>
            <span class="al-launch-tag">Shared admin view</span>
          </div>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Review mode" value="Check first" hint="Prepare the action here, then send it from your wallet." />
          <.stat_card title="Prepared action" value={if(@prepared, do: @prepared.action, else: "None yet")} hint="Most recent action you drafted" />
        </div>
      </section>

      <section id="contracts-entry" class="al-contract-grid" phx-hook="MissionMotion">
        <article class="al-panel al-contract-card">
          <p class="al-kicker">Launch mode</p>
          <h3>Open one launch job</h3>
          <p class="al-inline-note">
            Use this when you want deploy results, strategy state, vesting, or fee details.
          </p>
          <form method="get" action={~p"/contracts"} class="al-contract-form-grid">
            <input type="text" name="job_id" value={@job_id} placeholder="Launch job id" />
            <button type="submit" class="al-submit">Open launch view</button>
          </form>
        </article>

        <article class="al-panel al-contract-card">
          <p class="al-kicker">Subject mode</p>
          <h3>Open one subject</h3>
          <p class="al-inline-note">
            Use this when you want splitter, ingress, and registry tools for a launched token.
          </p>
          <form method="get" action={~p"/contracts"} class="al-contract-form-grid">
            <input type="text" name="subject_id" value={@subject_id} placeholder="Subject id" />
            <button type="submit" class="al-submit">Open subject view</button>
          </form>
        </article>

        <article class="al-panel al-contract-card">
          <p class="al-kicker">Admin mode</p>
          <h3>Stay on the shared factory view</h3>
          <p class="al-inline-note">
            Use the admin section below when you want global factory settings without drilling into
            one launch or subject.
          </p>
          <div class="al-action-row">
            <.link navigate={~p"/contracts"} class="al-ghost">Reset to admin</.link>
          </div>
        </article>
      </section>

      <%= if is_nil(@job_scope) and is_nil(@subject_scope) do %>
        <.empty_state
          title="No launch or subject is selected yet."
          body="Use the entry cards above to open a launch job or a subject. The shared admin view still stays available below."
        />
      <% end %>

      <%= if @job_scope do %>
        <section id="contracts-job" class="al-contract-grid" phx-hook="MissionMotion">
          <article class="al-panel al-contract-card">
            <p class="al-kicker">Settlement</p>
            <h3>Current post-auction branch</h3>
            <div class="al-contract-kv">
              <div><span>Settlement state</span><strong>{humanize_key(@settlement_summary.settlement_state)}</strong></div>
              <div><span>Recommended next move</span><strong>{humanize_key(@settlement_summary.recommended_action)}</strong></div>
              <div><span>Required signer</span><strong>{humanize_key(@settlement_summary.required_actor || "none")}</strong></div>
              <div><span>Fee ownership accepted</span><strong>{yes_no(@settlement_summary.ownership_status.all_accepted)}</strong></div>
            </div>
            <p :if={@settlement_summary.blocked_reason} class="al-inline-note">
              {@settlement_summary.blocked_reason}
            </p>
            <div class="al-contract-list">
              <div
                :for={action <- @settlement_summary.allowed_actions}
                class="al-contract-list-item"
              >
                <span>Allowed now</span>
                <strong>{humanize_key(action)}</strong>
              </div>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Launch deployment</p>
            <h3>Controller result and provenance</h3>
            <div class="al-contract-kv">
              <div><span>Deploy binary</span><strong>{@job_scope.controller.deploy_binary || "n/a"}</strong></div>
              <div><span>Workdir</span><strong>{@job_scope.controller.deploy_workdir || "n/a"}</strong></div>
              <div><span>Script target</span><strong>{@job_scope.controller.script_target || "n/a"}</strong></div>
              <div><span>Deploy tx</span><strong>{short_address(@job_scope.controller.deploy_tx_hash)}</strong></div>
            </div>
            <div class="al-contract-kv">
              <div :for={{label, value} <- @job_scope.controller.result_addresses}>
                <span>{humanize_key(label)}</span>
                <strong>{short_address(value)}</strong>
              </div>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Strategy</p>
            <h3>LBP runtime state</h3>
            <div class="al-contract-kv">
              <div><span>Strategy</span><strong>{short_address(@job_scope.strategy.address)}</strong></div>
              <div><span>Auction</span><strong>{short_address(@job_scope.strategy.auction_address)}</strong></div>
              <div><span>Migrated</span><strong>{yes_no(@job_scope.strategy.migrated)}</strong></div>
              <div><span>Strategy USDC</span><strong>{display_uint(@settlement_summary.balance_snapshot.strategy.usdc_balance)}</strong></div>
              <div><span>Strategy token</span><strong>{display_uint(@settlement_summary.balance_snapshot.strategy.token_balance)}</strong></div>
              <div><span>Pool id</span><strong>{short_hash(@job_scope.strategy.migrated_pool_id)}</strong></div>
              <div><span>Position id</span><strong>{display_uint(@job_scope.strategy.migrated_position_id)}</strong></div>
              <div><span>Liquidity</span><strong>{display_uint(@job_scope.strategy.migrated_liquidity)}</strong></div>
              <div><span>Currency for LP</span><strong>{display_uint(@job_scope.strategy.migrated_currency_for_lp)}</strong></div>
              <div><span>Token for LP</span><strong>{display_uint(@job_scope.strategy.migrated_token_for_lp)}</strong></div>
            </div>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="strategy" phx-value-action="migrate" phx-value-form_name="strategy_migrate">Prepare migrate</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="strategy" phx-value-action="recover_failed_auction" phx-value-form_name="strategy_recover_failed_auction">Prepare failed-auction recovery</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="strategy" phx-value-action="sweep_token" phx-value-form_name="strategy_sweep_token">Prepare sweep token</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="strategy" phx-value-action="sweep_currency" phx-value-form_name="strategy_sweep_currency">Prepare sweep currency</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Auction</p>
            <h3>Auction-side balances and return actions</h3>
            <div class="al-contract-kv">
              <div><span>Auction</span><strong>{short_address(@job_scope.auction.address)}</strong></div>
              <div><span>Graduated</span><strong>{yes_no(@job_scope.auction.graduated)}</strong></div>
              <div><span>Auction USDC</span><strong>{display_uint(@job_scope.auction.currency_balance)}</strong></div>
              <div><span>Auction token</span><strong>{display_uint(@job_scope.auction.token_balance)}</strong></div>
            </div>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="auction" phx-value-action="sweep_currency" phx-value-form_name="auction_sweep_currency">Prepare auction currency return</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="auction" phx-value-action="sweep_unsold_tokens" phx-value-form_name="auction_sweep_unsold_tokens">Prepare unsold token return</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Vesting</p>
            <h3>Release path and Safe rotation</h3>
            <div class="al-contract-kv">
              <div><span>Vesting wallet</span><strong>{short_address(@job_scope.vesting.address)}</strong></div>
              <div><span>Beneficiary</span><strong>{short_address(@job_scope.vesting.beneficiary)}</strong></div>
              <div><span>Pending beneficiary</span><strong>{short_address(@job_scope.vesting.pending_beneficiary)}</strong></div>
              <div><span>Rotation ETA</span><strong>{display_timestamp(@job_scope.vesting.pending_beneficiary_eta)}</strong></div>
              <div><span>Rotation delay</span><strong>{display_seconds(@job_scope.vesting.rotation_delay)}</strong></div>
              <div><span>Releasable token</span><strong>{display_uint(@job_scope.vesting.releasable_launch_token)}</strong></div>
            </div>
            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="vesting_beneficiary_rotation" />
              <input type="text" name="form[beneficiary]" value={form_value(@forms, "vesting_beneficiary_rotation", "beneficiary")} placeholder="New beneficiary Safe" />
            </form>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="vesting" phx-value-action="release" phx-value-form_name="vesting_release">Prepare release</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="vesting" phx-value-action="propose_beneficiary_rotation" phx-value-form_name="vesting_beneficiary_rotation">Prepare beneficiary proposal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="vesting" phx-value-action="cancel_beneficiary_rotation" phx-value-form_name="vesting_beneficiary_rotation">Prepare beneficiary cancel</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="vesting" phx-value-action="execute_beneficiary_rotation" phx-value-form_name="vesting_beneficiary_rotation">Prepare beneficiary execute</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Fee registry</p>
            <h3>Pool registration and locked hook state</h3>
            <div class="al-contract-kv">
              <div><span>Registry</span><strong>{short_address(@job_scope.fee_registry.address)}</strong></div>
              <div><span>Owner</span><strong>{short_address(@job_scope.fee_registry.owner)}</strong></div>
              <div><span>Pending owner</span><strong>{short_address(@job_scope.fee_registry.pending_owner)}</strong></div>
              <div><span>Ownership status</span><strong>{humanize_key(@job_scope.fee_registry.ownership_status)}</strong></div>
              <div><span>Pool id</span><strong>{short_hash(@job_scope.fee_registry.pool_id)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Hook enabled</span><strong>{yes_no(@job_scope.fee_registry.pool_config.hook_enabled)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Pool fee</span><strong>{display_uint(@job_scope.fee_registry.pool_config.pool_fee)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Tick spacing</span><strong>{display_int(@job_scope.fee_registry.pool_config.tick_spacing)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Treasury</span><strong>{short_address(@job_scope.fee_registry.pool_config.treasury)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Regent recipient</span><strong>{short_address(@job_scope.fee_registry.pool_config.regent_recipient)}</strong></div>
            </div>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_registry" phx-value-action="accept_ownership" phx-value-form_name="fee_registry_accept_ownership">Prepare ownership acceptance</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Fee vault</p>
            <h3>Treasury and Regent balances</h3>
            <div class="al-contract-kv">
              <div><span>Vault</span><strong>{short_address(@job_scope.fee_vault.address)}</strong></div>
              <div><span>Hook</span><strong>{short_address(@job_scope.fee_vault.hook)}</strong></div>
              <div><span>Owner</span><strong>{short_address(@job_scope.fee_vault.owner)}</strong></div>
              <div><span>Pending owner</span><strong>{short_address(@job_scope.fee_vault.pending_owner)}</strong></div>
              <div><span>Ownership status</span><strong>{humanize_key(@job_scope.fee_vault.ownership_status)}</strong></div>
              <div><span>Treasury token</span><strong>{display_uint(@job_scope.fee_vault.treasury_accrued.token)}</strong></div>
              <div><span>Treasury USDC</span><strong>{display_uint(@job_scope.fee_vault.treasury_accrued.usdc)}</strong></div>
              <div><span>Regent token</span><strong>{display_uint(@job_scope.fee_vault.regent_accrued.token)}</strong></div>
              <div><span>Regent USDC</span><strong>{display_uint(@job_scope.fee_vault.regent_accrued.usdc)}</strong></div>
            </div>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="fee_vault_withdraw_treasury" />
              <input type="text" name="form[currency]" value={form_value(@forms, "fee_vault_withdraw_treasury", "currency", @job_scope.job.token_address)} placeholder="Currency address" />
              <input type="text" name="form[amount]" value={form_value(@forms, "fee_vault_withdraw_treasury", "amount")} placeholder="Amount (raw units)" />
              <input type="text" name="form[recipient]" value={form_value(@forms, "fee_vault_withdraw_treasury", "recipient")} placeholder="Recipient address" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="fee_vault_withdraw_regent" />
              <input type="text" name="form[currency]" value={form_value(@forms, "fee_vault_withdraw_regent", "currency", @job_scope.job.token_address)} placeholder="Currency address" />
              <input type="text" name="form[amount]" value={form_value(@forms, "fee_vault_withdraw_regent", "amount")} placeholder="Amount (raw units)" />
              <input type="text" name="form[recipient]" value={form_value(@forms, "fee_vault_withdraw_regent", "recipient")} placeholder="Recipient address" />
            </form>

            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_vault" phx-value-action="withdraw_treasury" phx-value-form_name="fee_vault_withdraw_treasury">Prepare treasury withdrawal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_vault" phx-value-action="withdraw_regent_share" phx-value-form_name="fee_vault_withdraw_regent">Prepare Regent withdrawal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_vault" phx-value-action="accept_ownership" phx-value-form_name="fee_vault_accept_ownership">Prepare ownership acceptance</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Hook</p>
            <h3>Hook ownership handoff</h3>
            <div class="al-contract-kv">
              <div><span>Hook</span><strong>{short_address(@job_scope.hook.address)}</strong></div>
              <div><span>Owner</span><strong>{short_address(@job_scope.hook.owner)}</strong></div>
              <div><span>Pending owner</span><strong>{short_address(@job_scope.hook.pending_owner)}</strong></div>
              <div><span>Ownership status</span><strong>{humanize_key(@job_scope.hook.ownership_status)}</strong></div>
              <div><span>Pool id</span><strong>{short_hash(@job_scope.hook.pool_id)}</strong></div>
            </div>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="hook" phx-value-action="accept_ownership" phx-value-form_name="hook_accept_ownership">Prepare ownership acceptance</button>
            </div>
          </article>
        </section>
      <% end %>

      <%= if @subject_scope do %>
        <section id="contracts-subject" class="al-contract-grid" phx-hook="MissionMotion">
          <article class="al-panel al-contract-card">
            <p class="al-kicker">Subject</p>
            <h3>Revenue state</h3>
            <div class="al-contract-kv">
              <div><span>Subject id</span><strong>{short_hash(@subject_scope.subject.subject_id)}</strong></div>
              <div><span>Splitter</span><strong>{short_address(@subject_scope.subject.splitter_address)}</strong></div>
              <div><span>Default ingress</span><strong>{short_address(@subject_scope.subject.default_ingress_address)}</strong></div>
              <div><span>Total staked</span><strong>{@subject_scope.subject.total_staked}</strong></div>
              <div><span>Treasury residual</span><strong>{@subject_scope.subject.treasury_residual_usdc}</strong></div>
              <div><span>Protocol reserve</span><strong>{@subject_scope.subject.protocol_reserve_usdc}</strong></div>
            </div>
            <div class="al-contract-action-row">
              <.link navigate={~p"/subjects/#{@subject_id}"} class="al-submit">Open subject action page</.link>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Subject registry</p>
            <h3>Config, control, and identity links</h3>
            <div class="al-contract-kv">
              <div><span>Registry</span><strong>{short_address(@subject_scope.registry.address)}</strong></div>
              <div><span>Owner</span><strong>{short_address(@subject_scope.registry.owner)}</strong></div>
              <div><span>Treasury safe</span><strong>{short_address(@subject_scope.registry.subject_config && @subject_scope.registry.subject_config.treasury_safe)}</strong></div>
              <div><span>Active</span><strong>{yes_no(@subject_scope.registry.subject_config && @subject_scope.registry.subject_config.active)}</strong></div>
              <div><span>Label</span><strong>{@subject_scope.registry.subject_config && @subject_scope.registry.subject_config.label || "n/a"}</strong></div>
              <div><span>Connected wallet can manage</span><strong>{yes_no(@subject_scope.registry.connected_wallet_can_manage)}</strong></div>
            </div>
            <div class="al-contract-list">
              <div :for={link <- @subject_scope.registry.identity_links} class="al-contract-list-item">
                <span>{display_uint(link.chain_id)}</span>
                <span>{short_address(link.registry)}</span>
                <strong>{display_uint(link.agent_id)}</strong>
              </div>
            </div>
            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="registry_manager" />
              <input type="text" name="form[account]" value={form_value(@forms, "registry_manager", "account")} placeholder="Manager wallet" />
              <select name="form[enabled]">
                <option value="true" selected={form_value(@forms, "registry_manager", "enabled", "true") == "true"}>Enable</option>
                <option value="false" selected={form_value(@forms, "registry_manager", "enabled") == "false"}>Disable</option>
              </select>
            </form>
            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="registry_identity" />
              <input type="text" name="form[identity_chain_id]" value={form_value(@forms, "registry_identity", "identity_chain_id", "84532")} placeholder="Identity chain id" />
              <input type="text" name="form[identity_registry]" value={form_value(@forms, "registry_identity", "identity_registry")} placeholder="Identity registry" />
              <input type="text" name="form[identity_agent_id]" value={form_value(@forms, "registry_identity", "identity_agent_id")} placeholder="Identity agent id" />
            </form>
            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="registry_rotate_safe" />
              <input type="text" name="form[new_safe]" value={form_value(@forms, "registry_rotate_safe", "new_safe")} placeholder="New Agent Safe" />
            </form>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="registry" phx-value-action="set_subject_manager" phx-value-form_name="registry_manager">Prepare manager change</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="registry" phx-value-action="link_identity" phx-value-form_name="registry_identity">Prepare identity link</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="registry" phx-value-action="rotate_safe" phx-value-form_name="registry_rotate_safe">Prepare Safe sync</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Splitter</p>
            <h3>Advanced revenue controls</h3>
            <div class="al-contract-kv">
              <div><span>Owner</span><strong>{short_address(@subject_scope.splitter.owner)}</strong></div>
              <div><span>Paused</span><strong>{yes_no(@subject_scope.splitter.paused)}</strong></div>
              <div><span>Eligible share</span><strong>{display_bps_percent(@subject_scope.splitter.eligible_revenue_share_bps)}</strong></div>
              <div><span>Pending eligible share</span><strong>{display_bps_percent(@subject_scope.splitter.pending_eligible_revenue_share_bps)}</strong></div>
              <div><span>Share activation ETA</span><strong>{display_timestamp(@subject_scope.splitter.pending_eligible_revenue_share_eta)}</strong></div>
              <div><span>Share cooldown end</span><strong>{display_timestamp(@subject_scope.splitter.eligible_revenue_share_cooldown_end)}</strong></div>
              <div><span>Treasury recipient</span><strong>{short_address(@subject_scope.splitter.treasury_recipient)}</strong></div>
              <div><span>Pending treasury recipient</span><strong>{short_address(@subject_scope.splitter.pending_treasury_recipient)}</strong></div>
              <div><span>Treasury rotation ETA</span><strong>{display_timestamp(@subject_scope.splitter.pending_treasury_recipient_eta)}</strong></div>
              <div><span>Treasury rotation delay</span><strong>{display_seconds(@subject_scope.splitter.treasury_rotation_delay)}</strong></div>
              <div><span>Protocol recipient</span><strong>{short_address(@subject_scope.splitter.protocol_recipient)}</strong></div>
              <div><span>Protocol skim bps</span><strong>{display_uint(@subject_scope.splitter.protocol_skim_bps)}</strong></div>
              <div><span>Gross inflow</span><strong>{display_uint(@subject_scope.splitter.gross_inflow_usdc_raw)}</strong></div>
              <div><span>Regent skim</span><strong>{display_uint(@subject_scope.splitter.regent_skim_usdc_raw)}</strong></div>
              <div><span>Staker-eligible inflow</span><strong>{display_uint(@subject_scope.splitter.staker_eligible_inflow_usdc_raw)}</strong></div>
              <div><span>Treasury-reserved inflow</span><strong>{display_uint(@subject_scope.splitter.treasury_reserved_inflow_usdc_raw)}</strong></div>
              <div><span>Treasury reserve</span><strong>{display_uint(@subject_scope.splitter.treasury_reserved_usdc_raw)}</strong></div>
              <div><span>Label</span><strong>{@subject_scope.splitter.label || "n/a"}</strong></div>
            </div>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_paused" />
              <select name="form[paused]">
                <option value="true" selected={form_value(@forms, "splitter_paused", "paused") == "true"}>Pause</option>
                <option value="false" selected={form_value(@forms, "splitter_paused", "paused", "false") == "false"}>Unpause</option>
              </select>
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_label" />
              <input type="text" name="form[label]" value={form_value(@forms, "splitter_label", "label")} placeholder="Label" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_share" />
              <input type="text" name="form[share_bps]" value={form_value(@forms, "splitter_share", "share_bps")} placeholder="Eligible share bps" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_treasury_rotation" />
              <input type="text" name="form[recipient]" value={form_value(@forms, "splitter_treasury_rotation", "recipient")} placeholder="New treasury recipient Safe" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_protocol" />
              <input type="text" name="form[recipient]" value={form_value(@forms, "splitter_protocol", "recipient")} placeholder="Protocol recipient" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_sweeps" />
              <input type="text" name="form[amount]" value={form_value(@forms, "splitter_sweeps", "amount")} placeholder="Amount (raw units)" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_dust" />
              <input type="text" name="form[amount]" value={form_value(@forms, "splitter_dust", "amount")} placeholder="Dust amount (raw units)" />
            </form>

            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_paused" phx-value-form_name="splitter_paused">Prepare pause toggle</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_label" phx-value-form_name="splitter_label">Prepare label update</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="propose_eligible_revenue_share" phx-value-form_name="splitter_share">Prepare share proposal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="cancel_eligible_revenue_share" phx-value-form_name="splitter_share">Prepare share cancel</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="activate_eligible_revenue_share" phx-value-form_name="splitter_share">Prepare share activation</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="propose_treasury_recipient_rotation" phx-value-form_name="splitter_treasury_rotation">Prepare treasury proposal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="cancel_treasury_recipient_rotation" phx-value-form_name="splitter_treasury_rotation">Prepare treasury cancel</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="execute_treasury_recipient_rotation" phx-value-form_name="splitter_treasury_rotation">Prepare treasury execute</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_protocol_recipient" phx-value-form_name="splitter_protocol">Prepare protocol recipient</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="sweep_treasury_residual" phx-value-form_name="splitter_sweeps">Prepare treasury sweep</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="sweep_treasury_reserved" phx-value-form_name="splitter_sweeps">Prepare reserve sweep</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="sweep_protocol_reserve" phx-value-form_name="splitter_sweeps">Prepare protocol sweep</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="reassign_dust" phx-value-form_name="splitter_dust">Prepare dust reassignment</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Ingress</p>
            <h3>Factory and account controls</h3>
            <div class="al-contract-kv">
              <div><span>Factory</span><strong>{short_address(@subject_scope.ingress_factory.address)}</strong></div>
              <div><span>Owner</span><strong>{short_address(@subject_scope.ingress_factory.owner)}</strong></div>
              <div><span>Default ingress</span><strong>{short_address(@subject_scope.ingress_factory.default_ingress_address)}</strong></div>
              <div><span>Known accounts</span><strong>{display_uint(@subject_scope.ingress_factory.ingress_account_count)}</strong></div>
            </div>

            <div class="al-contract-list">
              <div :for={ingress <- @subject_scope.subject.ingress_accounts} class="al-contract-list-item">
                <span>{if ingress.is_default, do: "default", else: "ingress"}</span>
                <strong>{short_address(ingress.address)}</strong>
                <span>{ingress.usdc_balance} USDC</span>
              </div>
            </div>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="ingress_factory_create" />
              <input type="text" name="form[label]" value={form_value(@forms, "ingress_factory_create", "label")} placeholder="Ingress label" />
              <select name="form[make_default]">
                <option value="true" selected={form_value(@forms, "ingress_factory_create", "make_default") == "true"}>Create as default</option>
                <option value="false" selected={form_value(@forms, "ingress_factory_create", "make_default", "false") == "false"}>Create without default switch</option>
              </select>
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="ingress_factory_default" />
              <input type="text" name="form[ingress_address]" value={form_value(@forms, "ingress_factory_default", "ingress_address")} placeholder="Ingress address" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="ingress_account_label" />
              <input type="text" name="form[ingress_address]" value={form_value(@forms, "ingress_account_label", "ingress_address")} placeholder="Ingress address" />
              <input type="text" name="form[label]" value={form_value(@forms, "ingress_account_label", "label")} placeholder="New label" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="ingress_account_rescue" />
              <input type="text" name="form[ingress_address]" value={form_value(@forms, "ingress_account_rescue", "ingress_address")} placeholder="Ingress address" />
              <input type="text" name="form[token]" value={form_value(@forms, "ingress_account_rescue", "token")} placeholder="Token address" />
              <input type="text" name="form[amount]" value={form_value(@forms, "ingress_account_rescue", "amount")} placeholder="Amount (raw units)" />
              <input type="text" name="form[recipient]" value={form_value(@forms, "ingress_account_rescue", "recipient")} placeholder="Recipient" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="ingress_account_sweep" />
              <input type="text" name="form[ingress_address]" value={form_value(@forms, "ingress_account_sweep", "ingress_address")} placeholder="Ingress address" />
            </form>

            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="ingress_factory" phx-value-action="create" phx-value-form_name="ingress_factory_create">Prepare ingress create</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="ingress_factory" phx-value-action="set_default" phx-value-form_name="ingress_factory_default">Prepare default ingress change</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="ingress_account" phx-value-action="set_label" phx-value-form_name="ingress_account_label">Prepare ingress label</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="ingress_account" phx-value-action="rescue" phx-value-form_name="ingress_account_rescue">Prepare rescue</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="ingress_account" phx-value-action="sweep" phx-value-form_name="ingress_account_sweep">Prepare sweep</button>
            </div>
          </article>
        </section>
      <% end %>

      <section id="contracts-admin" class="al-contract-grid" phx-hook="MissionMotion">
        <article class="al-panel al-contract-card">
          <p class="al-kicker">Admin factories</p>
          <h3>Global prepare-only actions</h3>
          <div class="al-contract-kv">
            <div><span>Revenue share factory</span><strong>{short_address(@admin_scope && @admin_scope.admin_contracts.revenue_share_factory.address)}</strong></div>
            <div><span>Ingress factory</span><strong>{short_address(@admin_scope && @admin_scope.admin_contracts.revenue_ingress_factory.address)}</strong></div>
            <div><span>Strategy factory</span><strong>{short_address(@admin_scope && @admin_scope.admin_contracts.regent_lbp_strategy_factory.address)}</strong></div>
            <div><span>USDC</span><strong>{short_address(@admin_scope && @admin_scope.dependencies.usdc_address)}</strong></div>
          </div>

          <form phx-change="update_form" class="al-contract-form-grid">
            <input type="hidden" name="form_name" value="admin_revenue_share" />
            <input type="text" name="form[account]" value={form_value(@forms, "admin_revenue_share", "account")} placeholder="Authorized creator" />
            <select name="form[enabled]">
              <option value="true" selected={form_value(@forms, "admin_revenue_share", "enabled", "true") == "true"}>Enable</option>
              <option value="false" selected={form_value(@forms, "admin_revenue_share", "enabled") == "false"}>Disable</option>
            </select>
          </form>

          <form phx-change="update_form" class="al-contract-form-grid">
            <input type="hidden" name="form_name" value="admin_revenue_ingress" />
            <input type="text" name="form[account]" value={form_value(@forms, "admin_revenue_ingress", "account")} placeholder="Authorized creator" />
            <select name="form[enabled]">
              <option value="true" selected={form_value(@forms, "admin_revenue_ingress", "enabled", "true") == "true"}>Enable</option>
              <option value="false" selected={form_value(@forms, "admin_revenue_ingress", "enabled") == "false"}>Disable</option>
            </select>
          </form>

          <div class="al-contract-action-row">
            <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="admin" phx-value-resource="revenue_share_factory" phx-value-action="set_authorized_creator" phx-value-form_name="admin_revenue_share">Prepare revenue-share auth</button>
            <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="admin" phx-value-resource="revenue_ingress_factory" phx-value-action="set_authorized_creator" phx-value-form_name="admin_revenue_ingress">Prepare ingress auth</button>
          </div>
        </article>

        <article :if={@prepared} class="al-panel al-contract-card al-prepared-card">
          <p class="al-kicker">Prepared transaction</p>
          <h3>{@prepared.resource} / {@prepared.action}</h3>
          <div class="al-contract-kv">
            <div><span>Chain id</span><strong>{display_uint(@prepared.chain_id)}</strong></div>
            <div><span>Target</span><strong>{short_address(@prepared.target)}</strong></div>
            <div><span>Submission mode</span><strong>{@prepared.submission_mode}</strong></div>
          </div>
          <div class="al-action-row">
            <button type="button" class="al-submit" data-copy-value={Jason.encode!(@prepared.tx_request)}>Copy tx JSON</button>
            <button type="button" class="al-ghost" data-copy-value={@prepared.calldata}>Copy calldata</button>
          </div>
          <pre class="al-contract-json"><code>{Jason.encode!(@prepared, pretty: true)}</code></pre>
        </article>
      </section>
      </div>
    </.shell>
    """
  end

  defp load_console(socket) do
    job_scope = load_job_scope(socket.assigns.job_id, socket.assigns.current_human)
    subject_scope = load_subject_scope(socket.assigns.subject_id, socket.assigns.current_human)

    assign(socket,
      admin_scope: load_admin_scope(),
      job_scope: job_scope,
      settlement_summary: job_scope && Map.get(job_scope, :settlement),
      subject_scope: subject_scope,
      wallet_switch: wallet_switch_prompt(socket.assigns.current_human, job_scope, subject_scope)
    )
  end

  defp load_admin_scope do
    case context_module().admin_overview() do
      {:ok, payload} -> payload
      _ -> nil
    end
  end

  defp load_job_scope(nil, _current_human), do: nil

  defp load_job_scope(job_id, current_human) do
    case context_module().job_state(job_id, current_human) do
      {:ok, payload} -> payload
      _ -> nil
    end
  end

  defp load_subject_scope(nil, _current_human), do: nil

  defp load_subject_scope(subject_id, current_human) do
    case context_module().subject_state(subject_id, current_human) do
      {:ok, payload} -> payload
      _ -> nil
    end
  end

  defp default_forms do
    %{
      "fee_registry_hook" => %{"enabled" => "true"},
      "ingress_factory_create" => %{"make_default" => "false"},
      "registry_manager" => %{"enabled" => "true"},
      "splitter_paused" => %{"paused" => "false"},
      "splitter_share" => %{"share_bps" => "10000"},
      "admin_revenue_share" => %{"enabled" => "true"},
      "admin_revenue_ingress" => %{"enabled" => "true"}
    }
  end

  defp form_value(forms, form_name, key, fallback \\ "") do
    forms
    |> Map.get(form_name, %{})
    |> Map.get(key, fallback)
  end

  defp context_module do
    Application.get_env(:autolaunch, :contracts_live, [])
    |> Keyword.get(:context_module, Contracts)
  end

  defp short_address(nil), do: "n/a"

  defp short_address("0x" <> _rest = value) when byte_size(value) > 12,
    do: String.slice(value, 0, 8) <> "..." <> String.slice(value, -4, 4)

  defp short_address(value), do: to_string(value)

  defp short_hash(nil), do: "none"

  defp short_hash("0x" <> _rest = value) when byte_size(value) > 14,
    do: String.slice(value, 0, 10) <> "..." <> String.slice(value, -6, 6)

  defp short_hash(value), do: to_string(value)

  defp display_uint(nil), do: "n/a"
  defp display_uint(value) when is_integer(value), do: Integer.to_string(value)
  defp display_uint(value), do: to_string(value)

  defp display_bps_percent(nil), do: "n/a"
  defp display_bps_percent(0), do: "n/a"

  defp display_bps_percent(value) when is_integer(value) do
    percent =
      value
      |> Decimal.new()
      |> Decimal.div(Decimal.new(100))
      |> Decimal.normalize()
      |> Decimal.to_string(:normal)

    percent <> "%"
  end

  defp display_bps_percent(value), do: to_string(value)

  defp display_int(nil), do: "n/a"
  defp display_int(value) when is_integer(value), do: Integer.to_string(value)
  defp display_int(value), do: to_string(value)

  defp display_timestamp(nil), do: "n/a"
  defp display_timestamp(0), do: "n/a"

  defp display_timestamp(value) when is_integer(value) and value > 0 do
    value
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  rescue
    _ -> Integer.to_string(value)
  end

  defp display_timestamp(value), do: to_string(value)

  defp display_seconds(nil), do: "n/a"
  defp display_seconds(value) when is_integer(value), do: Integer.to_string(value) <> " seconds"
  defp display_seconds(value), do: to_string(value)

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no(nil), do: "n/a"

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp prepare_error(:invalid_address), do: "One of the addresses is invalid."
  defp prepare_error(:invalid_uint), do: "Amounts must be provided in whole onchain units."
  defp prepare_error(:invalid_string), do: "A text value is required."
  defp prepare_error(:invalid_boolean), do: "Choose a valid true or false option."

  defp prepare_error(:ingress_not_found),
    do: "That ingress account does not belong to the current subject."

  defp prepare_error(:subject_config_unavailable),
    do: "The current subject settings could not be loaded for this action."

  defp prepare_error(:safe_rotation_noop),
    do: "The new Safe must be different from the current one."

  defp prepare_error(:unsupported_action),
    do: "That contract action is not supported from this console."

  defp prepare_error(_reason), do: "The contract payload could not be prepared."

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp wallet_switch_prompt(nil, _job_scope, _subject_scope), do: nil

  defp wallet_switch_prompt(current_human, job_scope, subject_scope) do
    active_wallet = normalize_wallet(Map.get(current_human, :wallet_address))
    linked_wallets = linked_wallets(current_human)

    cond do
      target =
          linked_wallet_target(
            active_wallet,
            linked_wallets,
            get_in(job_scope, [:job, :owner_address])
          ) ->
        %{wallet_address: target}

      target =
          linked_wallet_target(
            active_wallet,
            linked_wallets,
            get_in(subject_scope, [:registry, :subject_config, :treasury_safe])
          ) ->
        %{wallet_address: target}

      true ->
        nil
    end
  end

  defp linked_wallet_target(active_wallet, linked_wallets, target_wallet) do
    normalized_target = normalize_wallet(target_wallet)

    if normalized_target && normalized_target != active_wallet &&
         normalized_target in linked_wallets,
       do: normalized_target,
       else: nil
  end

  defp linked_wallets(current_human) do
    [
      Map.get(current_human, :wallet_address)
      | List.wrap(Map.get(current_human, :wallet_addresses))
    ]
    |> Enum.map(&normalize_wallet/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_wallet(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalize_wallet(_value), do: nil
  defp route_css, do: @route_css
end
