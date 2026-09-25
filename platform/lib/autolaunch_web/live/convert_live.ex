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

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]
  import AutolaunchWeb.Components.ChainIcon

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Robinhood.Pool, as: RobinhoodPool
  alias Autolaunch.Stocks.Lab, as: StocksLab
  alias AutolaunchWeb.Paths

  @concurrency 4
  @read_timeout 30_000

  def mount(_params, _session, socket), do: {:ok, load(socket, true)}

  def handle_event("reload", _params, socket), do: {:noreply, load(socket, false)}

  # A conversion confirmed, so every row is read again. The previous rows stay
  # on screen while the chains answer, so each row keeps its form and notice.
  def handle_info(:reload_pool, socket), do: {:noreply, load(socket, false)}

  def render(assigns) do
    ~H"""
    <article id="autolaunch-convert" class="autolaunch-page">
      <header class="autolaunch-heading">
        <Regent.Structure.section_bar>
          <h1 class="rg-section-bar__label">REGENT's share of fees</h1>
        </Regent.Structure.section_bar>
        <p>
          Every Memestake launch keeps REGENT's share of its trading fees in stock until it is sold for USDC
          <.chain_icon chain={:base} /> or USDG <.chain_icon chain={:robinhood} />
          and sent to REGENT's revenue.
          Only the wallet chosen to sell it sees the sell form on each launch.
        </p>
        <div>
          <Regent.Primitives.button phx-click="reload" variant="secondary">
            Refresh
          </Regent.Primitives.button>
        </div>
      </header>

      <.chain
        id="convert-base"
        title={if Autolaunch.Lab.test_chain?(), do: "Base test network", else: "Base"}
        rows={@base}
        open?={StocksLab.configured?()}
        authenticated={@account_control.kind == :signed_in}
        current_human_id={current_human_id(@access_context)}
        session_lease={@session_lease}
      />
      <.chain
        id="convert-robinhood"
        title={if RobinhoodLab.test_chain?(), do: "Robinhood test network", else: "Robinhood Chain"}
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
  attr :rows, Phoenix.LiveView.AsyncResult, required: true
  attr :open?, :boolean, required: true
  attr :authenticated, :boolean, required: true
  attr :current_human_id, :any, required: true
  attr :session_lease, :any, required: true

  defp chain(assigns) do
    ~H"""
    <section id={@id} class="autolaunch-convert" aria-label={@title}>
      <h2 class="autolaunch-convert__title">{@title}</h2>
      <p :if={!@open?}>Memestake launches are not open on this network yet.</p>
      <p :if={@open? && @rows.loading && is_nil(@rows.result)} role="status">
        Reading the launches…
      </p>
      <p :if={@open? && @rows.failed && is_nil(@rows.result)} role="alert">
        The launches could not be read just now.
      </p>
      <p :if={@open? && @rows.result == []}>No Memestake token has launched yet.</p>
      <p :if={converter(@rows.result)} class="autolaunch-convert__muted">
        Converter wallet <span class="autolaunch-exact-value">{converter(@rows.result)}</span>
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
      do: with({:ok, tokens} <- Autolaunch.list_tokens(actor: nil), do: base_rows(tokens)),
      else: {:ok, %{base: []}}
  end

  defp base_rows(tokens) do
    rows =
      tokens
      |> Enum.filter(&graduated_memestock?/1)
      |> read_rows(fn token ->
        %{
          id: "convert-base-#{token.auction.id}",
          name: token.name,
          symbol: token.symbol,
          href: Paths.token(token.auction),
          launch: %{chain: :base, auction: token.auction},
          pool: Autolaunch.Pool.read(token.auction)
        }
      end)

    {:ok, %{base: rows}}
  end

  defp graduated_memestock?(%{auction: %{kind: :stocks, state: :graduated}}), do: true
  defp graduated_memestock?(_token), do: false

  defp robinhood_rows do
    if RobinhoodLab.configured?(),
      do:
        with(
          {:ok, tokens} <- Autolaunch.list_listed_tokens(actor: nil),
          do: robinhood_rows(tokens)
        ),
      else: {:ok, %{robinhood: []}}
  end

  defp robinhood_rows(tokens) do
    rows =
      tokens
      |> Enum.filter(&RobinhoodLab.chain?(&1.auction.chain_id))
      |> read_rows(fn token ->
        %{
          id: "convert-robinhood-#{token.auction.auction_address}",
          name: token.name,
          symbol: token.symbol,
          href: Paths.token(token.auction),
          launch: %{chain: :robinhood, auction: token.auction.auction_address},
          pool: RobinhoodPool.read(token.auction.auction_address)
        }
      end)

    {:ok, %{robinhood: rows}}
  end

  # Each launch's pool is its own read of the chain; the rows with the most
  # waiting come first.
  defp read_rows(records, row) do
    records
    |> Task.async_stream(row, max_concurrency: @concurrency, timeout: @read_timeout)
    |> Enum.map(fn {:ok, read} -> read end)
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
