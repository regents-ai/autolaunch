defmodule AutolaunchWeb.LaunchLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers

  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign_async(assign(socket, :record_id, id), :page, fn -> load_launch_page(id) end)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    assigns =
      assign(assigns,
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error)
      )

    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-launch-detail"
      class="autolaunch-page autolaunch-compact-detail"
    >
      <header class="autolaunch-heading">
        <p class="autolaunch-kicker">Autolaunch · Launch</p>
        <h1>{launch_label(@page_record)}</h1>
        <p>
          <Regent.Primitives.status>{display_action(@page_record.status)}</Regent.Primitives.status>
          · Chain {@page_record.chain_id}
        </p>
      </header>

      <section aria-labelledby="launch-auction-title">
        <h2 id="launch-auction-title">Linked auction</h2>
        <p :if={is_nil(@page_record.auction_id)} class="autolaunch-empty">
          No auction is linked yet.
        </p>
        <.link :if={@page_record.auction_id} navigate={"/auctions/#{@page_record.auction_id}"}>
          View linked auction
        </.link>
      </section>

      <.treasury_security report={report(@page_record)} surface="launch-detail" />

      <Regent.Primitives.disclosure id="launch-addresses" summary="Addresses and identity">
        <section aria-labelledby="launch-identity-title">
          <h2 id="launch-identity-title">Agent and token</h2>
          <dl>
            <div>
              <dt>Agent</dt><dd>{launch_agent(@page_record)}</dd>
            </div>
            <div>
              <dt>Agent ID</dt><dd>{@page_record.agent_id}</dd>
            </div>
            <div>
              <dt>Token name</dt><dd>{@page_record.token_name}</dd>
            </div>
            <div>
              <dt>Token symbol</dt><dd>{@page_record.token_symbol}</dd>
            </div>
            <div>
              <dt>Launch wallet</dt><dd>{display_text(@page_record.agent_safe_address)}</dd>
            </div>
          </dl>
        </section>

        <h2 id="launch-addresses-title">Published addresses</h2>
        <dl>
          <div>
            <dt>Auction</dt><dd>{display_text(@page_record.auction_address)}</dd>
          </div>
          <div>
            <dt>Token</dt><dd>{display_text(@page_record.token_address)}</dd>
          </div>
          <div>
            <dt>Auction rules</dt><dd>{display_text(@page_record.hook_address)}</dd>
          </div>
          <div>
            <dt>Revenue share</dt>
            <dd>{display_text(@page_record.revenue_share_splitter_address)}</dd>
          </div>
        </dl>
      </Regent.Primitives.disclosure>

      <Regent.Primitives.disclosure id="launch-history" summary="History">
        <section aria-labelledby="launch-progress-title">
          <h2 id="launch-progress-title">Progress</h2>
          <dl>
            <div>
              <dt>Current step</dt><dd>{display_action(@page_record.step)}</dd>
            </div>
            <div>
              <dt>Launch ID</dt><dd>{@page_record.job_id}</dd>
            </div>
          </dl>
        </section>
        <h2 id="launch-times-title">Timeline</h2>
        <dl>
          <div>
            <dt>Started</dt><dd>{display_time(@page_record.started_at)}</dd>
          </div>
          <div>
            <dt>Finished</dt><dd>{display_time(@page_record.finished_at)}</dd>
          </div>
          <div>
            <dt>Record added</dt><dd>{display_time(@page_record.inserted_at)}</dd>
          </div>
          <div>
            <dt>Last updated</dt><dd>{display_time(@page_record.updated_at)}</dd>
          </div>
        </dl>
      </Regent.Primitives.disclosure>
    </article>

    <section
      :if={@page_status == :empty}
      id="autolaunch-launch-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <h1>Launch not found</h1>
      <p>No public launch exists at {@record_id}.</p>
      <.link navigate="/launches">Return to Launches</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-launch-detail"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <h1>Launch unavailable</h1>
      <p>This launch could not be loaded right now.</p>
      <.link navigate="/launches">Return to Launches</.link>
    </section>
    """
  end
end
