defmodule AutolaunchWeb.TokenLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers
  import AutolaunchWeb.Components.MarketCard

  alias Autolaunch.Lab

  def mount(_params, _session, socket), do: {:ok, socket}

  # The identifier is read here so a patch to another token reloads the page
  # instead of keeping the previous record on screen.
  def handle_params(%{"token_id" => id}, _uri, socket) do
    {:noreply, socket |> assign(:record_id, id) |> load_page()}
  end

  def handle_event("retry", _params, socket), do: {:noreply, load_page(socket)}

  def render(assigns) do
    assigns =
      assign(assigns,
        local_lab?: Lab.enabled?(),
        page_record: page_record(assigns.page),
        page_status: page_status(assigns.page, :error),
        creator_connections: page_connections(assigns.page)
      )

    ~H"""
    <article
      :if={@page_status == :ready && @page_record}
      id="autolaunch-token-detail"
      class="autolaunch-page"
    >
      <header class="autolaunch-heading">
        <.link navigate="/tokens" class="market-back">← Tokens</.link>
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">{record_label(:token, @page_record)}</h1>
        </Regent.Structure.section_bar>
      </header>
      <.detail_card
        kind={:token}
        record={@page_record}
        creator_connections={@creator_connections}
      />
      <.exact_price id="token-exact-price" summary="Exact price" amount={@page_record.price_quote} />
      <.treasury_security
        :if={!@local_lab?}
        report={report(@page_record)}
        surface="token-detail"
      />
      <.lab_treasury_unavailable :if={@local_lab?} surface="token-detail" />
    </article>

    <p :if={@page_status == :loading} class="autolaunch-page" role="status">Loading…</p>

    <section
      :if={@page_status == :empty}
      id="autolaunch-token-detail"
      class="autolaunch-page autolaunch-empty"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token not found</h1>
      </Regent.Structure.section_bar>
      <p>No public token exists at {@record_id}.</p>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>

    <section
      :if={@page_status == :error}
      id="autolaunch-token-detail"
      class="autolaunch-page autolaunch-empty"
      role="alert"
    >
      <Regent.Structure.section_bar>
        <h1 class="rg-section-bar__label">Token unavailable</h1>
      </Regent.Structure.section_bar>
      <p>This token could not be loaded right now.</p>
      <Regent.Primitives.button phx-click="retry" variant="secondary">Retry</Regent.Primitives.button>
      <.link navigate="/tokens">Return to Tokens</.link>
    </section>
    """
  end

  defp load_page(socket) do
    id = socket.assigns.record_id
    assign_async(socket, :page, fn -> load_token_page(id) end, reset: true)
  end
end
