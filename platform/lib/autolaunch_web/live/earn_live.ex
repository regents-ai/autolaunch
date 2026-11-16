defmodule AutolaunchWeb.EarnLive do
  @moduledoc """
  /earn: lend USDC on Base through Aave from your own wallet. Each product in
  the catalog (`Autolaunch.Earn.Catalog`) has its terms (the rate now, what is
  supplied, what can be withdrawn now and, under a supply cap, its capacity),
  from the reading every visitor shares, at most ten seconds old, with the
  block it was read at named (`Autolaunch.Earn.SharedTerms`), beside its
  wallet panel (`AutolaunchWeb.EarnComponent`) for a deposit or withdrawal,
  and its risks in plain words.

  The terms are read when the page opens, when Refresh is pressed and each
  time a step on the product lands, on this page or another. A Refresh while
  a reading is under way starts nothing; a landed step starts a new reading
  at once, stopping the one under way. While a reading is under way the
  figures from the one before are not shown, so a figure from before a
  confirmed step is never shown as current; a reading that fails says so.
  Each reading also has the panel read its wallet and its preview again
  (`reads`). Deposit and Withdraw are the page's tabs (`?tab=withdraw`).

  With Earn switched off the address is the site's 404.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.Earn
  alias Autolaunch.Earn.{Answer, Catalog, SharedTerms}
  alias AutolaunchWeb.{EarnComponent, NotFoundError}
  alias Phoenix.LiveView.AsyncResult
  alias Regent.Primitives, as: P

  def mount(_params, _session, socket) do
    if Catalog.enabled?() do
      products = Catalog.products()
      ids = Enum.map(products, & &1.id)
      if connected?(socket), do: Enum.each(ids, &SharedTerms.subscribe/1)

      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/earn"))
       |> assign(
         products: products,
         terms: Map.new(ids, &{&1, AsyncResult.loading()}),
         reads: Map.new(ids, &{&1, 0}),
         decimals: %{},
         kind: :deposit,
         done: nil
       )
       |> read(ids)}
    else
      raise NotFoundError
    end
  end

  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       assign(socket, kind: if(params["tab"] == "withdraw", do: :withdraw, else: :deposit))}

  # A product whose reading is still under way is not read again.
  def handle_event("refresh", _params, socket) do
    idle = for %{id: id} <- socket.assigns.products, !socket.assigns.terms[id].loading, do: id
    {:noreply, read(socket, idle)}
  end

  def handle_event("dismiss_done", _params, socket), do: {:noreply, assign(socket, done: nil)}

  # A step on the product landed, here or on another page.
  def handle_info({:earn_changed, id}, socket), do: {:noreply, read(socket, [id])}
  def handle_info({:earn_done, done}, socket), do: {:noreply, assign(socket, done: done)}

  def handle_async({:terms, id}, {:ok, {:ok, %{terms: terms}}}, socket) do
    {:noreply,
     socket
     |> update(:terms, &Map.put(&1, id, AsyncResult.ok(terms)))
     |> update(:decimals, &Map.put(&1, id, terms.decimals))}
  end

  def handle_async({:terms, id}, {:ok, {:error, error}}, socket),
    do: {:noreply, failed(socket, id, Earn.reason(error))}

  def handle_async({:terms, id}, {:exit, reason}, socket),
    do: {:noreply, failed(socket, id, reason)}

  # Each reading starts from nothing shown, so figures from before it, and
  # from before a confirmed step, never pass for current ones. It stops the
  # one still under way, and the product's panel reads its wallet again.
  defp read(socket, ids) do
    Enum.reduce(ids, socket, fn id, socket ->
      socket
      |> update(:terms, &Map.put(&1, id, AsyncResult.loading()))
      |> update(:reads, &Map.update!(&1, id, fn reads -> reads + 1 end))
      |> cancel_async({:terms, id})
      |> start_async({:terms, id}, fn -> Earn.read_earn_terms(id) end)
    end)
  end

  defp failed(socket, id, reason),
    do:
      update(
        socket,
        :terms,
        &Map.update!(&1, id, fn read -> AsyncResult.failed(read, reason) end)
      )

  def render(assigns) do
    assigns = assign(assigns, human_id: current_human_id(assigns.access_context))

    ~H"""
    <article class="earn">
      <EarnComponent.toast :if={@done} id="earn-done" done={@done} dismiss="dismiss_done" />
      <header class="earn__header">
        <div class="earn__intro">
          <h1>Earn</h1>
          <p>Lend USDC on Base from your own wallet, and take it back when you choose.</p>
        </div>
        <P.last_read
          id="earn-read"
          at={read_at(@terms)}
          phx-click="refresh"
          label="Read the market again"
        />
      </header>

      <section
        :for={product <- @products}
        id={"earn-#{product.id}"}
        class="earn__product"
        aria-labelledby={"earn-#{product.id}-title"}
      >
        <div class="earn__card">
          <div class="earn__card-head">
            <h2 id={"earn-#{product.id}-title"}>{product.asset}</h2>
            <span class="earn__market">{product.market}</span>
            <span
              :if={@terms[product.id].ok?}
              class="earn__status"
              data-status={@terms[product.id].result.status}
            >
              {status_word(@terms[product.id].result.status)}
            </span>
          </div>

          <p :if={@terms[product.id].failed} class="earn__note" role="alert">
            The market couldn't be read just now. Try again in a moment.
          </p>
          <div
            :if={@terms[product.id].loading}
            class="earn__waiting"
            aria-busy="true"
            aria-label="Reading the market"
          >
            <span class="loading-block"></span>
          </div>

          <.terms
            :if={@terms[product.id].ok?}
            id={"earn-#{product.id}-terms"}
            product={product}
            terms={@terms[product.id].result}
          />

          <p class="earn__line">Borrowers on {product.protocol} pay interest on the USDC you lend.</p>
        </div>

        <div class="earn__act">
          <nav class="earn__tabs" aria-label="Deposit or withdraw">
            <.link patch={~p"/earn"} aria-current={@kind == :deposit && "page"}>Deposit</.link>
            <.link patch={~p"/earn?tab=withdraw"} aria-current={@kind == :withdraw && "page"}>
              Withdraw
            </.link>
          </nav>
          <.live_component
            :if={@decimals[product.id]}
            module={EarnComponent}
            id={"earn-#{product.id}-panel"}
            product={product}
            decimals={@decimals[product.id]}
            kind={@kind}
            reads={@reads[product.id]}
            session_lease={@session_lease}
            current_human_id={@human_id}
          />
          <div :if={!@decimals[product.id]} class="earn__waiting" aria-busy="true">
            <span class="loading-block"></span>
          </div>
        </div>

        <section class="earn__risks" aria-labelledby={"earn-#{product.id}-risks"}>
          <h2 id={"earn-#{product.id}-risks"}>Risks</h2>
          <ul>
            <li :for={risk <- Catalog.risks(product)}>{risk}</li>
          </ul>
        </section>
      </section>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :product, :map, required: true
  attr :terms, :map, required: true

  defp terms(assigns) do
    ~H"""
    <dl id={@id} class="earn__terms">
      <div class="earn__rate">
        <dt>Rate</dt>
        <dd>
          <strong>{Answer.yearly_percent(@terms.rate)}%</strong>
          <small>a year at today's rate, before compounding. It changes.</small>
        </dd>
      </div>
      <div>
        <dt>Supplied</dt>
        <dd>{EarnComponent.amount(@terms.supplied, @terms.decimals, @product.asset)}</dd>
      </div>
      <div>
        <dt>Available</dt>
        <dd>{EarnComponent.amount(@terms.available, @terms.decimals, @product.asset)}</dd>
      </div>
      <div>
        <dt>Capacity</dt>
        <dd>{capacity(@terms, @product)}</dd>
      </div>
    </dl>
    <p class="earn__block">
      Read at block {Integer.to_string(@terms.block.number)}, {Calendar.strftime(
        DateTime.from_unix!(@terms.block.timestamp),
        "%-d %b %Y, %H:%M:%S UTC"
      )}.
    </p>
    """
  end

  # The most one deposit can be before the market's supply cap.
  defp capacity(%{capacity: :uncapped}, _product), do: "No cap"

  defp capacity(%{capacity: {:left, left}, decimals: decimals}, product),
    do: EarnComponent.amount(left, decimals, product.asset)

  defp capacity(%{capacity: :full}, _product), do: "Full"

  defp status_word(:open), do: "Open"
  defp status_word(:frozen), do: "Frozen"
  defp status_word(:paused), do: "Paused"
  defp status_word(:inactive), do: "Closed"

  # When the newest reading on the page was taken.
  defp read_at(terms) do
    terms
    |> Map.values()
    |> Enum.filter(& &1.ok?)
    |> Enum.map(& &1.result.block.timestamp)
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> nil
      at -> DateTime.from_unix!(at)
    end
  end
end
