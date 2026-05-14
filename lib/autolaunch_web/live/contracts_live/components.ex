defmodule AutolaunchWeb.ContractsLive.Components do
  @moduledoc false

  use AutolaunchWeb, :html

  attr :prepared, :map, default: nil

  def hero(assigns) do
    ~H"""
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
    """
  end

  attr :job_id, :string, default: nil
  attr :subject_id, :string, default: nil
  attr :entry_errors, :map, default: %{}

  def entry_selector(assigns) do
    ~H"""
    <section id="contracts-entry" class="al-contract-grid" phx-hook="MissionMotion">
      <article class="al-panel al-contract-card">
        <p class="al-kicker">Launch mode</p>
        <h3>Open one launch job</h3>
        <p class="al-inline-note">
          Use this when you want deploy results, strategy state, vesting, or fee details.
        </p>
        <form id="contracts-job-entry-form" phx-submit="open_contract_scope" class="al-contract-form-grid">
          <input type="hidden" name="scope" value="job" />
          <input type="text" name="job_id" value={@job_id} placeholder="Launch job id" />
          <button type="submit" class="al-submit">Open launch view</button>
        </form>
        <p :if={@entry_errors[:job]} class="al-inline-note is-error">{@entry_errors[:job]}</p>
      </article>

      <article class="al-panel al-contract-card">
        <p class="al-kicker">Subject mode</p>
        <h3>Open one subject</h3>
        <p class="al-inline-note">
          Use this when you want splitter, ingress, and registry tools for a launched token.
        </p>
        <form id="contracts-subject-entry-form" phx-submit="open_contract_scope" class="al-contract-form-grid">
          <input type="hidden" name="scope" value="subject" />
          <input type="text" name="subject_id" value={@subject_id} placeholder="Subject id" />
          <button type="submit" class="al-submit">Open subject view</button>
        </form>
        <p :if={@entry_errors[:subject]} class="al-inline-note is-error">
          {@entry_errors[:subject]}
        </p>
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
    """
  end

  attr :prepared, :map, default: nil

  def prepared_preview(assigns) do
    ~H"""
    <article :if={@prepared} class="al-panel al-contract-card al-prepared-card">
      <p class="al-kicker">Prepared transaction</p>
      <h3>{@prepared.resource} / {@prepared.action}</h3>
      <div class="al-contract-kv">
        <div><span>Chain id</span><strong>{AutolaunchWeb.Format.display_uint(@prepared.chain_id)}</strong></div>
        <div><span>Target</span><strong>{AutolaunchWeb.Format.short_address(@prepared.wallet_action.to)}</strong></div>
        <div><span>Expires</span><strong>{@prepared.wallet_action.expires_at}</strong></div>
      </div>
      <div class="al-action-row">
        <button type="button" class="al-submit" data-copy-value={Jason.encode!(@prepared.wallet_action)}>Copy signing request</button>
        <button type="button" class="al-ghost" data-copy-value={@prepared.wallet_action.data}>Copy transaction data</button>
      </div>
      <pre class="al-contract-json"><code>{Jason.encode!(@prepared, pretty: true)}</code></pre>
    </article>
    """
  end
end
