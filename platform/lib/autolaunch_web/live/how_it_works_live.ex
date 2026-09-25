defmodule AutolaunchWeb.HowItWorksLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  alias AutolaunchWeb.ShareCard

  # Every figure here is a fixed contract rule: RegentLBPStrategy and
  # ConditionalVestingEscrowV1 (Revstake supply), StocksPreset and
  # StocksLaunchpadV1 (Memestake supply), RegentFeeHook, StocksFeeHookV1 and
  # RobinhoodFeeHookV1 (fees), SubjectSplitterV1 and MemestockSplitterCore
  # (staking rewards).
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(
         socket,
         :share,
         if(connected?(socket), do: nil, else: ShareCard.how_it_works_meta())
       )}

  def render(assigns) do
    ~H"""
    <main class="fact-page">
      <header class="autolaunch-heading">
        <div class="fact-page__title">
          <h1>How Autolaunch works</h1>
          <Regent.Primitives.button
            id="copy-agent-guide"
            class="copy-agent-guide"
            data-copy-agent-guide={~p"/llms.txt"}
            phx-update="ignore"
          >
            <span data-copy-agent-label aria-live="polite">Copy to Agent</span>
          </Regent.Primitives.button>
        </div>
        <p>Supply, trading fees and staking rewards for every Autolaunch token.</p>
      </header>

      <section class="fact-page__section" aria-labelledby="how-it-works-revstake">
        <h2 id="how-it-works-revstake">
          Revstake supply <span class="fact-page__total">100 billion</span>
        </h2>
        <p>
          Revstake token auctions have a 48 hour duration, with 10% of tokens for the auction, 5%
          locked in the trading pool, and 85% vesting to the launch's treasury over one year. This small amount
          of float is because launching a revstake is close in concept to a company doing a preseed
          round. Best practice is for the founders to retain 80-90% of equity.
        </p>
        <table class="fact-table">
          <thead>
            <tr>
              <th scope="col">Allocation</th>
              <th scope="col" class="fact-table__amount">Amount</th>
              <th scope="col">After a successful auction</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Auction</th>
              <td data-label="Amount" class="fact-table__amount">
                Up to <strong>10 billion (10%)</strong>
              </td>
              <td data-label="After a successful auction">Winning bidders claim what they bought.</td>
            </tr>
            <tr>
              <th scope="row">Liquidity reserve</th>
              <td data-label="Amount" class="fact-table__amount">
                Up to <strong>5 billion (5%)</strong>
              </td>
              <td data-label="After a successful auction">
                Paired with REGENT in a permanently locked trading position.
              </td>
            </tr>
            <tr>
              <th scope="row">Treasury</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong>85 billion (85%)</strong>
              </td>
              <td data-label="After a successful auction">
                Released to the launch's treasury over <strong>365 days</strong>, with any unsold
                auction tokens and unused reserve.
              </td>
            </tr>
          </tbody>
        </table>
        <p>
          The launcher of the revstake token is making an implicit promise to pass all future
          revenue through the revstake contract, where stakers receive a pro rata slice. Yes, there
          is a trust assumption here: a person or agent can launch a revstake token and then stop
          putting revenue through the contract (exit scam), go out of business, or only put a
          portion of revenue through the contract.
        </p>
      </section>

      <section class="fact-page__section" aria-labelledby="how-it-works-memestake">
        <h2 id="how-it-works-memestake">
          Memestake supply <span class="fact-page__total">1 billion</span>
        </h2>
        <p>
          Memestake launches last 24 hours, and have 80% of tokens for the auction and 20% locked in
          the trading pool. Stakers earn the onchain stock from fees.
        </p>
        <table class="fact-table">
          <thead>
            <tr>
              <th scope="col">Allocation</th>
              <th scope="col" class="fact-table__amount">Amount</th>
              <th scope="col">After a successful auction</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Auction</th>
              <td data-label="Amount" class="fact-table__amount">
                Up to <strong>800 million (80%)</strong>
              </td>
              <td data-label="After a successful auction">
                Winning bidders claim what they bought. Unsold tokens are burned.
              </td>
            </tr>
            <tr>
              <th scope="row">Liquidity reserve</th>
              <td data-label="Amount" class="fact-table__amount">
                Up to <strong>200 million (20%)</strong>
              </td>
              <td data-label="After a successful auction">
                Paired with the stock raised in a permanently locked trading position. Any unused
                reserve is burned.
              </td>
            </tr>
            <tr>
              <th scope="row">Creator, team or treasury</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong class="fact-page__hi">0</strong>
              </td>
              <td data-label="After a successful auction">No token allocation.</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="fact-page__section" aria-labelledby="how-it-works-fees">
        <h2 id="how-it-works-fees">Trading fees</h2>
        <p>
          The trading fee on revstake tokens benefits the creator's revstaking contract
          (<strong class="fact-page__hi">1%</strong>) and Regents Labs revstakers (<strong class="fact-page__hi">1%</strong>). Use
          <a href="https://regents.sh/stake">regents.sh/stake</a>
          to participate. The trading fee on memestake tokens benefits the memestakers
          (<strong class="fact-page__hi">1%</strong>) and Regents Labs revstakers (<strong class="fact-page__hi">1%</strong>). The trading pool also charges the standard <strong class="fact-page__hi">0.3%</strong>, and what the locked liquidity earns from it is added to the token's staking rewards.
        </p>
        <table class="fact-table">
          <thead>
            <tr>
              <th scope="col">Launch</th>
              <th scope="col">Fee paid in</th>
              <th scope="col">First 1%</th>
              <th scope="col">Second 1%</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Revstake <span class="fact-table__note">Base</span></th>
              <td data-label="Fee paid in">REGENT or the Revstake token, depending on the trade</td>
              <td data-label="First 1%">Sent to Regent</td>
              <td data-label="Second 1%">Added to the token's staking rewards</td>
            </tr>
            <tr>
              <th scope="row">Memestake <span class="fact-table__note">Base</span></th>
              <td data-label="Fee paid in">The paired stock, buying or selling</td>
              <td data-label="First 1%">Swapped to USDC for REGENT stakers</td>
              <td data-label="Second 1%">Added to the token's staking rewards</td>
            </tr>
            <tr>
              <th scope="row">
                Memestake <span class="fact-table__note">Robinhood Chain</span>
              </th>
              <td data-label="Fee paid in">The paired stock, buying or selling</td>
              <td data-label="First 1%">
                Swapped to USDG for REGENT stakers, held on Robinhood Chain until the transfer to Base is set up
              </td>
              <td data-label="Second 1%">Added to the token's staking rewards</td>
            </tr>
          </tbody>
        </table>
        <p>What each launch's locked liquidity earns is added to its staking rewards.</p>
      </section>

      <section class="fact-page__section" aria-labelledby="how-it-works-staking">
        <h2 id="how-it-works-staking">Staking rewards</h2>
        <table class="fact-table">
          <thead>
            <tr>
              <th scope="col">Launch</th>
              <th scope="col" class="fact-table__amount">Regent</th>
              <th scope="col">Stakers</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Revstake</th>
              <td data-label="Regent" class="fact-table__amount">
                <strong>2%</strong>
              </td>
              <td data-label="Stakers">
                The other 98%, in line with the share of supply staked. The rest goes to the token's
                treasury.
              </td>
            </tr>
            <tr>
              <th scope="row">Memestake</th>
              <td data-label="Regent" class="fact-table__amount">
                <strong>2%</strong>
              </td>
              <td data-label="Stakers">
                The other 98%, split by stake. With nobody staking, all of it goes to Regent.
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="fact-page__section" aria-labelledby="how-it-works-regent">
        <h2 id="how-it-works-regent">REGENT</h2>
        <p>
          Revstake auctions are priced in REGENT, and REGENT stakers receive Regent's share of every
          Autolaunch token's trading fees and staking rewards.
          <.link navigate={~p"/regent"}>About REGENT</.link>
        </p>
      </section>

      <details class="fact-more">
        <summary>Show details</summary>
        <ul class="fact-more__body">
          <li>
            Revstake fees come from the side of the trade you did not set: out of what you receive,
            or added to what you pay.
          </li>
          <li>
            Each fee is worked out on its own and rounded down, so 2.30% is a headline rate, not a
            quote.
          </li>
          <li>Memestake fees are held in the stock and paid onward after the trade.</li>
          <li>Regent's 2% comes out of staking rewards. It is not another trading fee.</li>
          <li>The rates are fixed in the contracts and cannot be changed.</li>
        </ul>
      </details>
    </main>
    """
  end
end
