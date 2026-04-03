defmodule AutolaunchWeb.ContractsLive do
  use AutolaunchWeb, :live_view

  alias Autolaunch.Contracts
  alias AutolaunchWeb.Live.Refreshable

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
     |> assign(:subject_scope, nil)
     |> assign(:admin_scope, nil)
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
    <.shell current_human={@current_human} active_view={@active_view}>
      <section id="contracts-hero" class="al-hero al-panel al-contracts-hero" phx-hook="MissionMotion">
        <div>
          <p class="al-kicker">Contracts console</p>
          <h2>Inspect the live launch stack and prepare operator transactions from one surface.</h2>
          <p class="al-subcopy">
            The main operator journey now lives in the CLI. This screen stays as the advanced layer
            for contract reads, deep inspection, and prepared multisig payloads after the guided flow
            has already told you what to do next.
          </p>

          <div class="al-contract-pill-row">
            <span class="al-launch-tag">Prepare-only admin actions</span>
            <span class="al-launch-tag">Job and subject deep links</span>
            <span class="al-launch-tag">Sepolia launch stack reads</span>
          </div>
        </div>

        <div class="al-stat-grid">
          <.stat_card title="Job scope" value={@job_id || "none"} hint="Launch stack context" />
          <.stat_card title="Subject scope" value={short_hash(@subject_id)} hint="Revenue and registry context" />
          <.stat_card title="Prepared tx" value={if(@prepared, do: @prepared.action, else: "none")} hint="Most recent payload" />
          <.stat_card title="Mode" value="Prepare only" hint="Admin actions export calldata instead of sending it" />
        </div>
      </section>

      <%= if is_nil(@job_scope) and is_nil(@subject_scope) do %>
        <.empty_state
          title="Choose a launch job or subject"
          body="Open this page from the launch queue or a subject page, or attach ?job_id=... or ?subject_id=... in the URL."
        />
      <% end %>

      <%= if @job_scope do %>
        <section id="contracts-job" class="al-contract-grid" phx-hook="MissionMotion">
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
              <div><span>Pool id</span><strong>{short_hash(@job_scope.strategy.migrated_pool_id)}</strong></div>
              <div><span>Position id</span><strong>{display_uint(@job_scope.strategy.migrated_position_id)}</strong></div>
              <div><span>Liquidity</span><strong>{display_uint(@job_scope.strategy.migrated_liquidity)}</strong></div>
              <div><span>Currency for LP</span><strong>{display_uint(@job_scope.strategy.migrated_currency_for_lp)}</strong></div>
              <div><span>Token for LP</span><strong>{display_uint(@job_scope.strategy.migrated_token_for_lp)}</strong></div>
            </div>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="strategy" phx-value-action="migrate" phx-value-form_name="strategy_migrate">Prepare migrate</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="strategy" phx-value-action="sweep_token" phx-value-form_name="strategy_sweep_token">Prepare sweep token</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="strategy" phx-value-action="sweep_currency" phx-value-form_name="strategy_sweep_currency">Prepare sweep currency</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Vesting</p>
            <h3>Release path</h3>
            <div class="al-contract-kv">
              <div><span>Vesting wallet</span><strong>{short_address(@job_scope.vesting.address)}</strong></div>
              <div><span>Releasable token</span><strong>{display_uint(@job_scope.vesting.releasable_launch_token)}</strong></div>
            </div>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="vesting" phx-value-action="release" phx-value-form_name="vesting_release">Prepare release</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Fee registry</p>
            <h3>Pool registration and hook state</h3>
            <div class="al-contract-kv">
              <div><span>Registry</span><strong>{short_address(@job_scope.fee_registry.address)}</strong></div>
              <div><span>Pool id</span><strong>{short_hash(@job_scope.fee_registry.pool_id)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Hook enabled</span><strong>{yes_no(@job_scope.fee_registry.pool_config.hook_enabled)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Pool fee</span><strong>{display_uint(@job_scope.fee_registry.pool_config.pool_fee)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Tick spacing</span><strong>{display_int(@job_scope.fee_registry.pool_config.tick_spacing)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Treasury</span><strong>{short_address(@job_scope.fee_registry.pool_config.treasury)}</strong></div>
              <div :if={@job_scope.fee_registry.pool_config}><span>Regent recipient</span><strong>{short_address(@job_scope.fee_registry.pool_config.regent_recipient)}</strong></div>
            </div>
            <form phx-change="update_form">
              <input type="hidden" name="form_name" value="fee_registry_hook" />
              <div class="al-inline-form">
                <select name="form[enabled]">
                  <option value="true" selected={form_value(@forms, "fee_registry_hook", "enabled", "true") == "true"}>Enable hook</option>
                  <option value="false" selected={form_value(@forms, "fee_registry_hook", "enabled") == "false"}>Disable hook</option>
                </select>
              </div>
            </form>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_registry" phx-value-action="set_hook_enabled" phx-value-form_name="fee_registry_hook">Prepare hook toggle</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Fee vault</p>
            <h3>Treasury and Regent balances</h3>
            <div class="al-contract-kv">
              <div><span>Vault</span><strong>{short_address(@job_scope.fee_vault.address)}</strong></div>
              <div><span>Hook</span><strong>{short_address(@job_scope.fee_vault.hook)}</strong></div>
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

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="fee_vault_set_hook" />
              <input type="text" name="form[hook]" value={form_value(@forms, "fee_vault_set_hook", "hook", @job_scope.hook.address)} placeholder="Hook address" />
            </form>

            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_vault" phx-value-action="withdraw_treasury" phx-value-form_name="fee_vault_withdraw_treasury">Prepare treasury withdrawal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_vault" phx-value-action="withdraw_regent_share" phx-value-form_name="fee_vault_withdraw_regent">Prepare Regent withdrawal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="job" phx-value-resource="fee_vault" phx-value-action="set_hook" phx-value-form_name="fee_vault_set_hook">Prepare hook update</button>
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
              <input type="text" name="form[identity_chain_id]" value={form_value(@forms, "registry_identity", "identity_chain_id", "11155111")} placeholder="Identity chain id" />
              <input type="text" name="form[identity_registry]" value={form_value(@forms, "registry_identity", "identity_registry")} placeholder="Identity registry" />
              <input type="text" name="form[identity_agent_id]" value={form_value(@forms, "registry_identity", "identity_agent_id")} placeholder="Identity agent id" />
            </form>
            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="registry" phx-value-action="set_subject_manager" phx-value-form_name="registry_manager">Prepare manager change</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="registry" phx-value-action="link_identity" phx-value-form_name="registry_identity">Prepare identity link</button>
            </div>
          </article>

          <article class="al-panel al-contract-card">
            <p class="al-kicker">Splitter</p>
            <h3>Advanced revenue controls</h3>
            <div class="al-contract-kv">
              <div><span>Owner</span><strong>{short_address(@subject_scope.splitter.owner)}</strong></div>
              <div><span>Paused</span><strong>{yes_no(@subject_scope.splitter.paused)}</strong></div>
              <div><span>Treasury recipient</span><strong>{short_address(@subject_scope.splitter.treasury_recipient)}</strong></div>
              <div><span>Protocol recipient</span><strong>{short_address(@subject_scope.splitter.protocol_recipient)}</strong></div>
              <div><span>Protocol skim bps</span><strong>{display_uint(@subject_scope.splitter.protocol_skim_bps)}</strong></div>
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
              <input type="hidden" name="form_name" value="splitter_recipients" />
              <input type="text" name="form[treasury_recipient]" value={form_value(@forms, "splitter_recipients", "treasury_recipient")} placeholder="Treasury recipient" />
              <input type="text" name="form[protocol_recipient]" value={form_value(@forms, "splitter_recipients", "protocol_recipient")} placeholder="Protocol recipient" />
              <input type="text" name="form[skim_bps]" value={form_value(@forms, "splitter_recipients", "skim_bps")} placeholder="Protocol skim bps" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_withdrawals" />
              <input type="text" name="form[amount]" value={form_value(@forms, "splitter_withdrawals", "amount")} placeholder="Amount (raw units)" />
              <input type="text" name="form[recipient]" value={form_value(@forms, "splitter_withdrawals", "recipient")} placeholder="Recipient address" />
            </form>

            <form phx-change="update_form" class="al-contract-form-grid">
              <input type="hidden" name="form_name" value="splitter_dust" />
              <input type="text" name="form[amount]" value={form_value(@forms, "splitter_dust", "amount")} placeholder="Dust amount (raw units)" />
            </form>

            <div class="al-contract-action-row">
              <button type="button" class="al-submit" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_paused" phx-value-form_name="splitter_paused">Prepare pause toggle</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_label" phx-value-form_name="splitter_label">Prepare label update</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_treasury_recipient" phx-value-form_name="splitter_recipients">Prepare treasury recipient</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_protocol_recipient" phx-value-form_name="splitter_recipients">Prepare protocol recipient</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="set_protocol_skim_bps" phx-value-form_name="splitter_recipients">Prepare skim update</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="withdraw_treasury_residual" phx-value-form_name="splitter_withdrawals">Prepare treasury withdrawal</button>
              <button type="button" class="al-ghost" phx-click="prepare_action" phx-value-scope="subject" phx-value-resource="splitter" phx-value-action="withdraw_protocol_reserve" phx-value-form_name="splitter_withdrawals">Prepare protocol withdrawal</button>
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
    </.shell>
    """
  end

  defp load_console(socket) do
    assign(socket,
      admin_scope: load_admin_scope(),
      job_scope: load_job_scope(socket.assigns.job_id, socket.assigns.current_human),
      subject_scope: load_subject_scope(socket.assigns.subject_id, socket.assigns.current_human)
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

  defp display_int(nil), do: "n/a"
  defp display_int(value) when is_integer(value), do: Integer.to_string(value)
  defp display_int(value), do: to_string(value)

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

  defp prepare_error(:unsupported_action),
    do: "That contract action is not supported from this console."

  defp prepare_error(_reason), do: "The contract payload could not be prepared."

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
