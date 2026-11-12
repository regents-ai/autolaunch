defmodule AutolaunchWeb.ConvertLive do
  @moduledoc """
  Every graduated memestock launch on Base and on Robinhood, with REGENT's
  share of its trading fees waiting in the fee hook: one page from which the
  wallet the Safe named as converter sells each launch's share in turn.

  Each chain's launches are read on their own, so a slow or failing chain
  leaves the other on screen. Every visitor sees what is waiting; the convert
  form on each row appears only for the converter wallet.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers,
    only: [current_human_id: 1, spend_page_read: 1]

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias AutolaunchWeb.Paths

  # Leaves out a token whose auction an operator hid.
  @shown [filter: [auction: [hidden: false]]]

  @concurrency 4
  @read_timeout Application.compile_env!(:autolaunch, :convert_read_timeout)

  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(AutolaunchWeb.PublicDocuments.page("/convert")) |> load(true)}

  # Refresh reads every launch's fees from both chains: each press spends one
  # of the viewer's page reads, and past them the rows shown stay. Nothing
  # here reaches a wallet.
  def handle_event("reload", _params, socket) do
    case spend_page_read(socket) do
      :ok -> {:noreply, load(socket, false)}
      :limited -> {:noreply, socket}
    end
  end

  # A conversion confirmed, so every row is read again. The previous rows stay
  # on screen while the chains answer, so each row keeps its form and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load(socket, false)}

  def render(assigns) do
    ~H"""
    <article id="autolaunch-convert" class="autolaunch-page">
      <header class="autolaunch-heading">
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">REGENT Fees</h1>
        </Regent.Structure.section_bar>
        <div>
          <Regent.Primitives.button phx-click="reload" variant="secondary">
            Refresh
          </Regent.Primitives.button>
        </div>
      </header>

      <.chain
        id="convert-base"
        title={if Autolaunch.Lab.test_chain?(), do: "Base test network", else: "Base"}
        address_chain={if Autolaunch.Lab.test_chain?(), do: "test", else: "base"}
        rows={@base}
        open?={StocksLab.configured?()}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.chain
        id="convert-robinhood"
        title={if RobinhoodLab.test_chain?(), do: "Robinhood test network", else: "Robinhood Chain"}
        address_chain={if RobinhoodLab.test_chain?(), do: "test", else: "robinhood"}
        rows={@robinhood}
        open?={RobinhoodLab.configured?()}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :address_chain, :string, required: true, doc: "the chain addresses open on"
  attr :rows, Phoenix.LiveView.AsyncResult, required: true
  attr :open?, :boolean, required: true
  attr :authenticated, :boolean, required: true
  attr :current_human_id, :any, required: true
  attr :session_lease, :any, required: true

  defp chain(assigns) do
    ~H"""
    <section id={@id} class="autolaunch-convert" aria-label={@title}>
      <h2 class="autolaunch-convert__title">{@title}</h2>
      <p :if={!@open?}>Memestock launches are not open on this network yet.</p>
      <AutolaunchWeb.Components.Loading.placeholder
        :if={@open? && @rows.loading && is_nil(@rows.result)}
        label="Reading the launches"
      />
      <p :if={@open? && @rows.failed && is_nil(@rows.result)} role="alert">
        The launches could not be read just now.
      </p>
      <p :if={@open? && @rows.result == []}>No Memestock token has graduated yet.</p>
      <p :if={converter(@rows.result)} class="autolaunch-convert__muted">
        Converter wallet
        <Regent.Primitives.address
          id={"#{@id}-converter"}
          address={converter(@rows.result)}
          chain={@address_chain}
        />
      </p>
      <div :for={row <- @rows.result || []} id={"#{row.id}-row"} class="autolaunch-convert__row">
        <h3 class="autolaunch-convert__name">
          <.link navigate={row.href}>{row.name} · {row.symbol}</.link>
        </h3>
        <p :if={match?({:ok, _pool}, row.pool)} class="autolaunch-convert__muted">
          {waiting(row.pool)}
        </p>
        <p :if={match?({:error, _reason}, row.pool)} role="alert">
          This launch's fees could not be read just now.
        </p>
        <.live_component
          :if={match?({:ok, _pool}, row.pool)}
          module={AutolaunchWeb.ConvertComponent}
          id={row.id}
          title={"REGENT's share of #{row.symbol}"}
          launch={row.launch}
          pool={elem(row.pool, 1)}
          authenticated={@authenticated}
          current_human_id={@current_human_id}
          session_lease={@session_lease}
        />
      </div>
    </section>
    """
  end

  defp load(socket, reset?) do
    socket
    |> assign_async(:base, &base_rows/0, reset: reset?)
    |> assign_async(:robinhood, &robinhood_rows/0, reset: reset?)
  end

  defp base_rows do
    if StocksLab.configured?(),
      do:
        with(
          {:ok, tokens} <- Autolaunch.list_tokens(actor: nil, query: @shown),
          do: base_rows(tokens)
        ),
      else: {:ok, %{base: []}}
  end

  defp base_rows(tokens) do
    rows =
      tokens
      |> Enum.filter(&match?(%{auction: %{kind: :stocks, state: :graduated}}, &1))
      |> read_rows(&Autolaunch.Pool.read(&1.auction), fn token, pool ->
        %{
          id: "convert-base-#{token.auction.id}",
          name: token.name,
          symbol: token.symbol,
          href: Paths.token(token.auction),
          launch: %{chain: :base, auction: token.auction},
          pool: pool
        }
      end)

    {:ok, %{base: rows}}
  end

  defp robinhood_rows do
    if RobinhoodLab.configured?(),
      do:
        with(
          {:ok, tokens} <- Autolaunch.list_listed_tokens(actor: nil, query: @shown),
          do: robinhood_rows(tokens)
        ),
      else: {:ok, %{robinhood: []}}
  end

  defp robinhood_rows(tokens) do
    rows =
      tokens
      |> Enum.filter(&RobinhoodLab.chain?(&1.auction.chain_id))
      |> read_rows(&RobinhoodPool.read(&1.auction), fn token, pool ->
        %{
          id: "convert-robinhood-#{token.auction.auction_address}",
          name: token.name,
          symbol: token.symbol,
          href: Paths.token(token.auction),
          launch: %{chain: :robinhood, auction: token.auction},
          pool: pool
        }
      end)

    {:ok, %{robinhood: rows}}
  end

  # Each launch's pool is its own read of the chain, and one that takes too
  # long is that launch's row unread; the rows with the most waiting come
  # first.
  defp read_rows(tokens, read, row) do
    tokens
    |> Task.async_stream(read,
      max_concurrency: @concurrency,
      timeout: @read_timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip_with(tokens, fn
      {:ok, pool}, token -> row.(token, pool)
      {:exit, :timeout}, token -> row.(token, {:error, :timeout})
    end)
    |> Enum.sort_by(&waiting_amount/1, {:desc, Decimal})
  end

  defp waiting_amount(%{pool: {:ok, pool}}), do: Decimal.new(pool.fees.regent.accrued)
  defp waiting_amount(_unread), do: Decimal.new(-1)

  defp waiting({:ok, pool}),
    do: "#{pool.fees.regent.accrued} #{pool.currency.symbol} waiting"

  # Every launch on a chain shares one fee hook, so one wallet converts them all.
  defp converter(rows) when is_list(rows) do
    Enum.find_value(rows, fn
      %{pool: {:ok, pool}} -> pool.fees.regent.converter
      _unread -> nil
    end)
  end

  defp converter(_rows), do: nil
end
