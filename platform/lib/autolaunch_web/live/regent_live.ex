defmodule AutolaunchWeb.RegentLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  alias Autolaunch.Lab
  alias Autolaunch.RegentFacts
  alias AutolaunchWeb.TokenDisplay

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:local_lab?, Lab.enabled?())
     |> assign_async(:facts, fn ->
       case RegentFacts.read() do
         {:ok, facts} -> {:ok, %{facts: facts}}
         {:error, reason} -> {:error, reason}
       end
     end)}
  end

  # Every figure and link here is public Base mainnet. A local-fork site says
  # so, because the fork carries its own test REGENT that none of this reaches.
  def render(assigns) do
    ~H"""
    <main class="regent-page">
      <header class="autolaunch-heading">
        <h1>REGENT</h1>
        <p>The quote token for Autolaunch auctions.</p>
      </header>

      <p :if={@local_lab?} id="regent-scope" class="regent-scope" role="note">
        Public Base mainnet data and links. The test REGENT on this fork is separate and is
        not bought, staked or redeemed here.
      </p>

      <div :if={@facts.loading} id="regent-loading" class="regent-status">
        Reading the token.
      </div>

      <dl :if={@facts.ok?} id="regent-facts" class="regent-facts">
        <dt>Name</dt>
        <dd id="regent-name">{@facts.result.name}</dd>
        <dt>Symbol</dt>
        <dd id="regent-symbol">{@facts.result.symbol}</dd>
        <dt>Address</dt>
        <dd id="regent-address">
          <.link href={"https://basescan.org/token/#{@facts.result.address}"}>
            {@facts.result.address}
          </.link>
        </dd>
        <dt>Decimals</dt>
        <dd id="regent-decimals">{@facts.result.decimals}</dd>
        <dt>Total supply</dt>
        <dd id="regent-total-supply">
          <TokenDisplay.amount amount={@facts.result.total_supply} unit={@facts.result.symbol} />
        </dd>
        <dt>Total staked</dt>
        <dd id="regent-total-staked">
          <TokenDisplay.amount amount={@facts.result.total_staked} unit={@facts.result.symbol} />
        </dd>
      </dl>
      <p :if={@facts.ok?} id="regent-block">
        Read at {if @local_lab?, do: "Base mainnet block", else: "block"} {@facts.result.block_number}
      </p>

      <p :if={@facts.failed} id="regent-unavailable" class="regent-status">
        REGENT facts are unavailable right now.
      </p>

      <p>Every Autolaunch auction is quoted in REGENT.</p>

      <nav class="regent-links" aria-describedby={if @local_lab?, do: "regent-scope"}>
        <a
          id="regent-buy"
          class="rg-button rg-button--primary"
          href={AutolaunchWeb.Components.TokenLinks.buy()}
          target="_blank"
          rel="noopener noreferrer"
        >
          <span class="rg-button__label">Buy REGENT <span aria-hidden="true">↗</span></span>
        </a>
        <a
          id="regent-chart"
          class="rg-button rg-button--secondary"
          href={AutolaunchWeb.Components.TokenLinks.chart()}
          target="_blank"
          rel="noopener noreferrer"
        >
          View REGENT Chart <span aria-hidden="true">↗</span>
        </a>
        <.link
          class="rg-button rg-button--secondary"
          id="regent-stake"
          href="https://regents.sh/stake"
        >Stake REGENT</.link>
        <.link
          class="rg-button rg-button--secondary"
          id="regent-redeem"
          href="https://regents.sh/redeem"
        >Redeem</.link>
      </nav>
    </main>
    """
  end
end
