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
        local_lab?: Lab.enabled?(),
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error),
        tokens: page_list(assigns.page, :tokens),
        actions: page_list(assigns.page, :actions),
        settlements: page_list(assigns.page, :settlements)
      )

    ~H"""
    <p :if={@page_status == :loading} class="autolaunch-loading" role="status">Loading subject…</p>
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-subject-detail"
      class="autolaunch-page autolaunch-compact-detail"
    >
      <header class="autolaunch-heading">
        <.link navigate="/subjects" class="market-back">← Subjects</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{subject_label(@page_record)}</h1>
        </Regent.Structure.section_bar>
        <p>{display_text(@page_record.subject_kind)} · Chain {@page_record.chain_id}</p>
      </header>

      <.treasury_security
        :if={!@local_lab?}
        report={report(@page_record)}
        surface="subject-detail"
      />
      <.lab_treasury_unavailable :if={@local_lab?} surface="subject-detail" />

      <section class="autolaunch-record-section" aria-labelledby="subject-revenue-title">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label" id="subject-revenue-title">Revenue</h2>
        </Regent.Structure.section_bar>
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
            <dt>Protocol fees (USDC base units)</dt>
            <dd>{display_text(@page_record.protocol_fee_usdc_total_raw)}</dd>
          </div>
          <div>
            <dt>REGENT emissions (base units)</dt>
            <dd>{display_text(@page_record.regent_emission_total_raw)}</dd>
          </div>
          <div>
            <dt>Pending buyback (USDC base units)</dt>
            <dd>{display_text(@page_record.pending_buyback_usdc_raw)}</dd>
          </div>
        </dl>
      </section>

      <.live_component
        :if={
          !Autolaunch.Prelaunch.read_only?() && !@local_lab? &&
            @page_record.chain_id != Lab.chain_id()
        }
        module={AutolaunchWeb.SubjectWalletComponent}
        id="autolaunch-subject-wallet"
        subject={@page_record}
        authenticated={@account_control && @account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <section :if={Autolaunch.Prelaunch.read_only?()} class="prelaunch-actions">
        <h2>Staking and payments</h2>
        <p>Wallet actions will be available after contract deployment.</p>
        <Regent.Primitives.button disabled>Stake</Regent.Primitives.button>
        <Regent.Primitives.button disabled variant="secondary">Make a payment</Regent.Primitives.button>
      </section>
      <section
        :if={!Autolaunch.Prelaunch.read_only?() && @local_lab?}
        id="autolaunch-subject-wallet-unavailable"
        class="autolaunch-empty"
        role="status"
      >
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label">Staking and payments</h2>
        </Regent.Structure.section_bar>
        <p>
          Not available on this Base fork. Only launches and bids run against the fork, so
          this subject's wallet actions stay off rather than reaching Base mainnet.
        </p>
      </section>

      <section id="subject-related-tokens" aria-labelledby="subject-related-tokens-title">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label" id="subject-related-tokens-title">Related tokens</h2>
        </Regent.Structure.section_bar>
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
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label" id="subject-recent-actions-title">Recent actions</h2>
        </Regent.Structure.section_bar>
        <.subject_action_list
          actions={@actions}
          empty_copy="No subject actions yet."
          id_prefix="subject-action"
        />
      </section>

      <Regent.Primitives.disclosure id="subject-addresses" summary="Addresses">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label" id="subject-addresses-title">
            Linked token and addresses
          </h2>
        </Regent.Structure.section_bar>
        <dl>
          <div>
            <dt>Subject ID</dt><dd>{@page_record.subject_id}</dd>
          </div>
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
      </Regent.Primitives.disclosure>

      <section class="autolaunch-record-section" aria-labelledby="subject-settlement-title">
        <Regent.Structure.section_bar>
          <h2 class="rg-section-bar__label" id="subject-settlement-title">Settlement history</h2>
        </Regent.Structure.section_bar>
        <p :for={{status, count} <- Enum.sort(Enum.frequencies_by(@settlements, & &1.status))}>
          {count} · {display_text(status)}
        </p>
        <Regent.Primitives.disclosure
          id="subject-settlement-history"
          summary={"Settlement details · #{length(@settlements)}"}
        >
          <.subject_action_list
            actions={@settlements}
            empty_copy="No settlements yet."
            id_prefix="subject-settlement"
          />
        </Regent.Primitives.disclosure>
      </section>
    </article>

    <section
      :if={@page_status == :empty}
      id="autolaunch-subject-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Subject not found</h1>
      </Regent.Structure.section_bar>
      <p>No public subject exists at {@record_id}.</p>
      <.link navigate="/subjects">Return to Subjects</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-subject-detail"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Subject unavailable</h1>
      </Regent.Structure.section_bar>
      <p>This subject could not be loaded right now.</p>
      <.link navigate="/subjects">Return to Subjects</.link>
    </section>
    """
  end
end
