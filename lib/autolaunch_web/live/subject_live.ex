defmodule AutolaunchWeb.SubjectLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  alias Autolaunch.Lab
  alias Autolaunch.Token

  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign_async(assign(socket, :record_id, id), :page, fn -> load_subject_page(id) end)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    assigns =
      assign(assigns,
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error),
        tokens: page_list(assigns.page, :tokens),
        actions: page_list(assigns.page, :actions),
        settlements: page_list(assigns.page, :settlements)
      )

    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-subject-detail"
      class="autolaunch-page"
    >
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Autolaunch · Subject</p>
        <h1>{subject_label(@page_record)}</h1>
        <p>
          Revenue sharing and settlement history for this {display_text(@page_record.subject_kind)}.
        </p>
      </header>

      <.treasury_security report={report(@page_record)} surface="subject-detail" />

      <section aria-labelledby="subject-identity-title">
        <h2 id="subject-identity-title">Subject details</h2>
        <dl>
          <div>
            <dt>Subject ID</dt><dd>{@page_record.subject_id}</dd>
          </div>
          <div>
            <dt>Type</dt><dd>{display_text(@page_record.subject_kind)}</dd>
          </div>
          <div>
            <dt>Chain</dt><dd>{@page_record.chain_id}</dd>
          </div>
        </dl>
      </section>

      <section aria-labelledby="subject-addresses-title">
        <h2 id="subject-addresses-title">Linked token and addresses</h2>
        <dl>
          <div>
            <dt>Token</dt><dd>{display_text(@page_record.token_address)}</dd>
          </div>
          <div>
            <dt>Revenue split</dt><dd>{display_text(@page_record.splitter_address)}</dd>
          </div>
          <div>
            <dt>Revenue entry</dt><dd>{display_text(@page_record.ingress_address)}</dd>
          </div>
          <div>
            <dt>Treasury</dt><dd>{display_text(@page_record.treasury_address)}</dd>
          </div>
          <div>
            <dt>Factory</dt><dd>{display_text(@page_record.factory_address)}</dd>
          </div>
          <div>
            <dt>Creator</dt><dd>{display_text(@page_record.creator_address)}</dd>
          </div>
        </dl>
      </section>

      <.live_component
        :if={@page_record.chain_id != Lab.chain_id()}
        module={AutolaunchWeb.SubjectWalletComponent}
        id="autolaunch-subject-wallet"
        subject={@page_record}
        authenticated={@account_control && @account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />

      <section aria-labelledby="subject-revenue-title">
        <h2 id="subject-revenue-title">Revenue</h2>
        <dl>
          <div>
            <dt>Starting protocol share</dt>
            <dd>{display_bps(@page_record.protocol_skim_bps_snapshot)}</dd>
          </div>
          <div>
            <dt>Current protocol share</dt>
            <dd>{display_bps(@page_record.current_protocol_skim_bps)}</dd>
          </div>
          <div>
            <dt>Protocol fees</dt>
            <dd>{display_text(@page_record.protocol_fee_usdc_total_raw)}</dd>
          </div>
          <div>
            <dt>REGENT emissions</dt>
            <dd>{display_text(@page_record.regent_emission_total_raw)}</dd>
          </div>
        </dl>
      </section>

      <section id="subject-related-tokens" aria-labelledby="subject-related-tokens-title">
        <h2 id="subject-related-tokens-title">Related tokens</h2>
        <p :if={@tokens == []} class="autolaunch-empty">No related tokens yet.</p>
        <ol :if={@tokens != []} class="autolaunch-record-list">
          <li :for={token <- @tokens}>
            <% presentation = Token.presentation(token) %>
            <.link navigate={"/tokens/#{token.id}"}>
              <strong>{presentation.name} · {presentation.symbol}</strong>
              <span>{presentation.summary || "No public token summary yet."}</span>
            </.link>
          </li>
        </ol>
      </section>

      <section id="subject-recent-actions" aria-labelledby="subject-recent-actions-title">
        <h2 id="subject-recent-actions-title">Recent actions</h2>
        <.subject_action_list
          actions={@actions}
          empty_copy="No subject actions yet."
          id_prefix="subject-action"
        />
      </section>

      <section id="subject-settlement-history" aria-labelledby="subject-settlement-title">
        <h2 id="subject-settlement-title">Settlement history</h2>
        <dl>
          <div>
            <dt>Pending buyback</dt>
            <dd>{display_text(@page_record.pending_buyback_usdc_raw)}</dd>
          </div>
        </dl>

        <.subject_action_list
          actions={@settlements}
          empty_copy="No settlements yet."
          id_prefix="subject-settlement"
        />
      </section>
    </article>

    <section
      :if={@page_status == :empty}
      id="autolaunch-subject-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <h1>Subject not found</h1>
      <p>No public subject exists at {@record_id}.</p>
      <.link navigate="/subjects">Return to Subjects</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-subject-detail"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <h1>Subject unavailable</h1>
      <p>This subject could not be loaded right now.</p>
      <.link navigate="/subjects">Return to Subjects</.link>
    </section>
    """
  end
end
