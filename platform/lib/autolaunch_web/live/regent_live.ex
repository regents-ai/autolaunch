defmodule AutolaunchWeb.RegentLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  alias Autolaunch.Lab
  alias Autolaunch.RegentFacts
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.Components.{RegentNext, TokenLinks}
  alias AutolaunchWeb.TokenDisplay

  @revenue_sources [
    {"Regents Labs", ["REGENT/ETH pool fees (0.1–0.3% of volume)", "Paid agent services"]},
    {"Autolaunch",
     ["1% of every Autolaunch token trade", "2% of every Autolaunch token's staking rewards"]},
    {"Techtree", ["5% of paid artifact sales", "Paid agent training environments"]},
    {"Patchbay", ["10% of priority question payments"]}
  ]

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/regent"))
     |> assign(:local_lab?, Lab.test_chain?())
     |> assign(:design, if(socket.assigns.live_action == :regent_next, do: :next, else: :current))
     |> assign(:revenue_sources, @revenue_sources)
     |> assign_async(:facts, fn ->
       case RegentFacts.read() do
         {:ok, facts} -> {:ok, %{facts: facts}}
         {:error, reason} -> {:error, reason}
       end
     end)}
  end

  def render(assigns), do: page(assigns)

  # The new page, in preview at /next/regent: where the USDC went, deposit by
  # deposit and source by source, how the next one would split, Memestake's
  # two chains kept apart, and REGENT emissions as a stream of their own.
  # Its links carry their own ids: the top bar's REGENT menu already uses the
  # current page's.
  defp page(%{design: :next} = assigns) do
    ~H"""
    <main class="fact-page regent-next">
      <header class="autolaunch-heading">
        <h1>REGENT</h1>
        <p>
          $REGENT is the value token for all Regents Labs products. Stake it to earn USDC from those
          products and REGENT emissions. Revstake auctions are priced in REGENT.
        </p>
        <p class="regent-next-preview">
          This is the new REGENT page. <.link navigate="/regent">Open the current page</.link>
        </p>
      </header>

      <p :if={@local_lab?} id="regent-next-scope" class="regent-scope" role="note">
        Public Base mainnet data and links. The test REGENT on this fork is separate and is
        not bought, staked or redeemed here.
      </p>

      <nav class="regent-links" aria-describedby={if @local_lab?, do: "regent-next-scope"}>
        <a
          id="regent-next-buy"
          class="rg-button rg-button--primary"
          href={TokenLinks.buy()}
          target="_blank"
          rel="noopener noreferrer"
        >
          <span class="rg-button__label">Buy REGENT <span aria-hidden="true">↗</span></span>
        </a>
        <.link
          class="rg-button rg-button--secondary"
          id="regent-next-stake"
          href="https://regents.sh/stake"
        >
          Stake REGENT
        </.link>
        <a
          id="regent-next-chart"
          class="rg-button rg-button--secondary"
          href={TokenLinks.chart()}
          target="_blank"
          rel="noopener noreferrer"
        >
          View REGENT Chart <span aria-hidden="true">↗</span>
        </a>
        <.link
          class="rg-button rg-button--secondary"
          id="regent-next-redeem"
          href="https://regents.sh/redeem"
        >
          Redeem
        </.link>
      </nav>

      <p :if={@facts.loading} id="regent-next-loading" class="regent-status">
        Loading REGENT figures…
      </p>
      <p :if={@facts.failed} id="regent-next-unavailable" class="regent-status">
        REGENT figures are unavailable right now.
      </p>

      <div :if={@facts.ok?} class="regent-next-layout">
        <RegentNext.deposit_allocation facts={@facts.result} />
        <RegentNext.next_split facts={@facts.result} />
        <RegentNext.emissions facts={@facts.result} />
        <RegentNext.deposits_by_source facts={@facts.result} />
        <RegentNext.memestake_sources facts={@facts.result} />
        <section
          id="regent-next-yours"
          class="regent-next-card"
          aria-labelledby="regent-next-yours-title"
        >
          <header class="regent-next-card__head">
            <h2 id="regent-next-yours-title">Your rewards</h2>
          </header>
          <p>
            Stake, unstake, claim or compound from your own wallet. Every step needs your signature.
          </p>
          <p class="regent-next-muted">
            Your USDC and REGENT rewards are not shown here. They are on the staking page.
          </p>
          <.link class="regent-next-link" href="https://regents.sh/stake">
            See your rewards on regents.sh
          </.link>
        </section>
      </div>

      <dl :if={@facts.ok?} id="regent-next-supply" class="regent-figures">
        <div>
          <dt>REGENT staked</dt>
          <dd><TokenDisplay.amount amount={@facts.result.total_staked} unit="REGENT" /></dd>
        </div>
        <div>
          <dt>Circulating REGENT</dt>
          <dd><TokenDisplay.amount amount={@facts.result.circulating_supply} unit="REGENT" /></dd>
        </div>
        <div>
          <dt>Circulating market cap</dt>
          <dd>{market_cap(@facts.result)}</dd>
        </div>
        <div>
          <dt>Total REGENT</dt>
          <dd><TokenDisplay.amount amount={@facts.result.total_supply} unit="REGENT" /></dd>
        </div>
      </dl>

      <section class="fact-page__section" aria-labelledby="regent-next-products">
        <h2 id="regent-next-products">What each product is set up to pay in</h2>
        <p>
          Figures on this page come only from recorded deposits. This list is what each product
          is set up to pay into staking.
        </p>
        <table class="fact-table">
          <thead>
            <tr>
              <th scope="col">Product</th>
              <th scope="col">Pays in</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{product, streams} <- @revenue_sources}>
              <th scope="row">{product}</th>
              <td data-label="Pays in">
                <span :for={stream <- streams} class="regent-stream">{stream}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <.circulating :if={@facts.ok?} facts={@facts.result} />

      <.contracts :if={@facts.ok?} facts={@facts.result} />
    </main>
    """
  end

  # Every figure and link here is public Base mainnet. A local-fork site says
  # so, because the fork carries its own test REGENT that none of this reaches.
  defp page(assigns) do
    ~H"""
    <main class="fact-page">
      <header class="autolaunch-heading">
        <h1>REGENT</h1>
        <p>
          $REGENT is the value token for all Regents Labs products. Stake it to earn USDC from those
          products and REGENT emissions. Revstake auctions are priced in REGENT.
        </p>
      </header>

      <p :if={@local_lab?} id="regent-scope" class="regent-scope" role="note">
        Public Base mainnet data and links. The test REGENT on this fork is separate and is
        not bought, staked or redeemed here.
      </p>

      <nav class="regent-links" aria-describedby={if @local_lab?, do: "regent-scope"}>
        <a
          id="regent-buy"
          class="rg-button rg-button--primary"
          href={TokenLinks.buy()}
          target="_blank"
          rel="noopener noreferrer"
        >
          <span class="rg-button__label">Buy REGENT <span aria-hidden="true">↗</span></span>
        </a>
        <.link
          class="rg-button rg-button--secondary"
          id="regent-stake"
          href="https://regents.sh/stake"
        >
          Stake REGENT
        </.link>
        <a
          id="regent-chart"
          class="rg-button rg-button--secondary"
          href={TokenLinks.chart()}
          target="_blank"
          rel="noopener noreferrer"
        >
          View REGENT Chart <span aria-hidden="true">↗</span>
        </a>
        <.link
          class="rg-button rg-button--secondary"
          id="regent-redeem"
          href="https://regents.sh/redeem"
        >
          Redeem
        </.link>
      </nav>

      <p :if={@facts.loading} id="regent-loading" class="regent-status">Loading REGENT figures…</p>
      <p :if={@facts.failed} id="regent-unavailable" class="regent-status">
        REGENT figures are unavailable right now.
      </p>

      <dl :if={@facts.ok?} id="regent-figures" class="regent-figures">
        <div class="regent-figures__usdc">
          <dt>USDC revenue</dt>
          <dd>
            <span>
              <small>Last 7 days</small>
              <strong class={@facts.result.usdc_received_7d != :unavailable && "fact-page__hi"}>
                {usdc(@facts.result.usdc_received_7d)}
              </strong>
            </span>
            <span>
              <small>Lifetime</small>
              <strong>{usdc(@facts.result.usdc_received_lifetime)}</strong>
            </span>
          </dd>
        </div>
        <div>
          <dt>REGENT staked</dt>
          <dd><TokenDisplay.amount amount={@facts.result.total_staked} unit="REGENT" /></dd>
        </div>
        <div>
          <dt>Circulating REGENT</dt>
          <dd><TokenDisplay.amount amount={@facts.result.circulating_supply} unit="REGENT" /></dd>
        </div>
        <div>
          <dt>Circulating market cap</dt>
          <dd>{market_cap(@facts.result)}</dd>
        </div>
        <div>
          <dt>Total REGENT</dt>
          <dd><TokenDisplay.amount amount={@facts.result.total_supply} unit="REGENT" /></dd>
        </div>
      </dl>

      <section class="fact-page__section" aria-labelledby="regent-why">
        <h2 id="regent-why">Why stake</h2>
        <dl class="regent-reasons">
          <div>
            <dt>USDC revenue</dt>
            <dd>
              Stakers share the USDC paid into staking. Each staker's cut is their share of all
              REGENT.
            </dd>
          </div>
          <div>
            <dt>REGENT emissions</dt>
            <dd :if={@facts.ok?}>
              Currently <strong class="fact-page__hi">{@facts.result.emission_apr_percent}%</strong>
              a year, paid in REGENT while the reward supply lasts. The rate can change.
            </dd>
            <dd :if={!@facts.ok?}>
              Paid in REGENT while the reward supply lasts. The rate can change.
            </dd>
          </div>
          <div>
            <dt>You stay in control</dt>
            <dd>
              Stake, unstake, claim or compound from your own wallet. Every step needs your
              signature.
            </dd>
          </div>
        </dl>
      </section>

      <section class="fact-page__section" aria-labelledby="regent-revenue">
        <h2 id="regent-revenue">Where the USDC comes from</h2>
        <table class="fact-table">
          <thead>
            <tr>
              <th scope="col">Product</th>
              <th scope="col">Revenue</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{product, streams} <- @revenue_sources}>
              <th scope="row">{product}</th>
              <td data-label="Revenue">
                <span :for={stream <- streams} class="regent-stream">{stream}</span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <.circulating :if={@facts.ok?} facts={@facts.result} />

      <.contracts :if={@facts.ok?} facts={@facts.result} />
    </main>
    """
  end

  attr :facts, :map, required: true

  # How much of the circulating supply is staked, and the four holdings it
  # leaves out.
  defp circulating(assigns) do
    ~H"""
    <section
      class="fact-page__section"
      aria-labelledby="regent-circulating"
    >
      <h2 id="regent-circulating">Circulating supply</h2>
      <p :if={@facts.staked_share_bps != :unavailable} id="regent-staked-share">
        <strong class="fact-page__hi">{percent(@facts.staked_share_bps)}</strong>
        of circulating REGENT is staked.
      </p>
      <div
        :if={@facts.staked_share_bps != :unavailable}
        class="regent-share"
        aria-hidden="true"
      >
        <span style={"width: #{percent(@facts.staked_share_bps)}"}></span>
      </div>
      <table class="fact-table">
        <thead>
          <tr>
            <th scope="col">Not circulating</th>
            <th scope="col" class="fact-table__amount">Amount</th>
            <th scope="col">When it circulates</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={holding <- holdings(@facts)}>
            <th scope="row">
              <a
                href={"https://basescan.org/address/#{holding.address}"}
                target="_blank"
                rel="noopener noreferrer"
              >
                {holding.name}
              </a>
            </th>
            <td data-label="Amount" class="fact-table__amount">
              <TokenDisplay.amount amount={holding.amount} unit="REGENT" />
            </td>
            <td data-label="When it circulates">{holding.release}</td>
          </tr>
        </tbody>
      </table>
      <p>
        Circulating REGENT is the total less these four. Read at Base block {Amounts.grouped(
          Integer.to_string(@facts.block_number)
        )}.
      </p>
    </section>
    """
  end

  attr :facts, :map, required: true

  defp contracts(assigns) do
    ~H"""
    <details class="fact-more">
      <summary>Show details</summary>
      <dl class="fact-more__body regent-contracts">
        <dt>REGENT token</dt>
        <dd>
          <a
            href={"https://basescan.org/token/#{@facts.token_address}"}
            target="_blank"
            rel="noopener noreferrer"
          >
            {@facts.token_address}
          </a>
        </dd>
        <dt>Staking contract</dt>
        <dd>
          <a
            href={"https://basescan.org/address/#{@facts.staking_address}"}
            target="_blank"
            rel="noopener noreferrer"
          >
            {@facts.staking_address}
          </a>
        </dd>
        <dt>Updated</dt>
        <dd>Figures are read from Base about once a minute.</dd>
      </dl>
    </details>
    """
  end

  # The four holdings the circulating supply leaves out, each with the words for
  # how it comes back. Only the vault has dates; they are the chain's own.
  defp holdings(facts) do
    [
      %{
        name: "Clanker vault",
        address: facts.clanker_vault.address,
        amount: facts.clanker_vault.amount,
        release:
          "Locked until #{day(facts.clanker_vault.locked_until)}, then released gradually until #{day(facts.clanker_vault.vested_by)}."
      },
      %{
        name: "Regent treasury",
        address: facts.treasury.address,
        amount: facts.treasury.amount,
        release: "Held by Regent. No release date."
      },
      %{
        name: "Animata redeemer",
        address: facts.animata_redeemer.address,
        amount: facts.animata_redeemer.amount,
        release:
          "As Animata I and II holders redeem: 5 million REGENT per token, over seven days."
      },
      %{
        name: "Staking rewards",
        address: facts.reward_inventory.address,
        amount: facts.reward_inventory.amount,
        release: "Paid to stakers as REGENT emissions."
      }
    ]
  end

  defp day(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")

  defp usdc(:unavailable), do: "Unavailable"
  defp usdc(amount), do: "#{amount |> cents() |> Amounts.grouped()} USDC"

  defp market_cap(%{price_usd: :unavailable}), do: "Unavailable"

  defp market_cap(%{price_usd: price, circulating_supply: circulating}) do
    dollars =
      price
      |> Decimal.new()
      |> Decimal.mult(Decimal.new(circulating))
      |> Decimal.round(0, :down)
      |> Decimal.to_string(:normal)

    "$" <> Amounts.grouped(dollars)
  end

  # Figures are written to the cent and never rounded up.
  defp cents(amount),
    do: amount |> Decimal.new() |> Decimal.round(2, :down) |> Decimal.to_string(:normal)

  defp percent(bps), do: "#{bps |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2)}%"
end
