defmodule AutolaunchWeb.HowItWorksLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  alias Autolaunch.Stocks.FeeSchedule
  alias AutolaunchWeb.ShareCard

  # Every figure here is a fixed contract rule: RegentLBPStrategyV2 and
  # ConditionalVestingEscrowV2 (Revstake supply), StocksPreset (Memestake
  # supply), RegentFeeHook and the Memestake fee hooks (fees), SubjectSplitterV1
  # and MemestockSplitterCore (staking rewards).
  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign(AutolaunchWeb.PublicDocuments.page("/how-it-works"))
       |> assign(
         share: if(connected?(socket), do: nil, else: ShareCard.how_it_works_meta()),
         agent_guide: AutolaunchWeb.PublicDocuments.agent_guide()
       )}

  def render(assigns) do
    ~H"""
    <main class="fact-page">
      <header class="autolaunch-heading">
        <div class="fact-page__title">
          <h1>How Autolaunch works</h1>
          <Regent.Primitives.copy_button
            id="copy-agent-guide"
            text={@agent_guide}
            variant="primary"
            class="copy-agent-guide"
          >
            Copy to Agent
          </Regent.Primitives.copy_button>
        </div>
        <p>Supply, trading fees and staking rewards for every Autolaunch token.</p>
      </header>

      <section class="fact-page__section" aria-labelledby="how-it-works-revstake">
        <h2 id="how-it-works-revstake">
          Revstake supply <span class="fact-page__total">100 billion</span>
        </h2>
        <p>
          Revstake token auctions have a 48 hour duration, with 20% of tokens for the auction, up to 10%
          locked in the trading pool, and 70% vesting to the launch's treasury over one year. This small amount
          of float is because launching a revstake is close in concept to a company doing a preseed
          round. Best practice is for the founders to retain most of the equity.
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
                <strong>20 billion (20%)</strong>
              </td>
              <td data-label="After a successful auction">Winning bidders claim what they bought.</td>
            </tr>
            <tr>
              <th scope="row">Liquidity reserve</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong>Up to 10 billion (10%)</strong>
              </td>
              <td data-label="After a successful auction">
                Paired with up to half the REGENT raised in a permanently locked trading position.
                The pool opens at the auction's final clearing price.
              </td>
            </tr>
            <tr>
              <th scope="row">Treasury</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong>70 billion (70%)</strong>
              </td>
              <td data-label="After a successful auction">
                Released to the launch's treasury over <strong>365 days</strong>, with any of the
                liquidity reserve the pool did not take. The treasury also receives at least half the
                REGENT raised.
              </td>
            </tr>
          </tbody>
        </table>
        <p>
          Every auction opens at the lowest price it accepts. Its minimum is tiny, about a billionth
          of a REGENT, so any real bid lets the launch go ahead. If the auction doesn't reach its
          minimum, every bidder takes back their full bid and all 100 billion tokens are burned.
        </p>
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
          Memestake launches last 24 hours. 49.5% of the tokens are sold in the auction, 49.5% is
          locked in the trading pool with everything the auction raised, and 1% goes to the token's
          creator over 30 days. Stakers earn the onchain stock from fees.
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
                <strong>495 million (49.5%)</strong>
              </td>
              <td data-label="After a successful auction">
                Winning bidders claim what they bought.
              </td>
            </tr>
            <tr>
              <th scope="row">Liquidity reserve</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong>495 million (49.5%)</strong>
              </td>
              <td data-label="After a successful auction">
                Paired with all the stock raised in a permanently locked trading position. The pool
                opens at the auction's final clearing price. The rest of the reserve is locked in a
                second position that holds only the new token.
              </td>
            </tr>
            <tr>
              <th scope="row">Creator</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong>10 million (1%)</strong>
              </td>
              <td data-label="After a successful auction">
                Released to the token's creator block by block over <strong>30 days</strong>
                from when the pool opens. Anyone can send the release, and it always pays the
                creator. The creator also earns a share of trading fees.
              </td>
            </tr>
          </tbody>
        </table>
        <p>
          Every auction opens at the lowest price it accepts. Its minimum is the whole sale at that
          price, a small fraction of one share. If the auction doesn't reach it, every bidder takes
          back their full bid and all 1 billion tokens are burned.
        </p>
        <p>
          The first four Memestake tokens (BITE, JollyB, AGI and RDOG) keep the terms they launched
          with: 80% sold, 20% in the pool, and a 1% fee each to REGENT stakers and the token's
          stakers.
        </p>
      </section>

      <section class="fact-page__section" aria-labelledby="how-it-works-fees">
        <h2 id="how-it-works-fees">Trading fees</h2>
        <p>
          The trading fee on revstake tokens benefits the creator's revstaking contract
          (<strong class="fact-page__hi">2%</strong>) and REGENT stakers (<strong class="fact-page__hi">1%</strong>). Use
          <a href="https://regents.sh/stake">regents.sh/stake</a>
          to participate. The trading fee on memestake tokens benefits the memestakers
          (<strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :stakers).rate}</strong>), REGENT stakers (<strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :regent).rate}</strong>) and the token's creator (<strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :creator).rate}</strong>). The trading pool also charges the standard <strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :pool).rate}</strong>, and what the locked liquidity earns from it is added to the token's staking rewards.
        </p>
        <table class="fact-table">
          <thead>
            <tr>
              <th scope="col">Launch</th>
              <th scope="col">Fee paid in</th>
              <th scope="col">Where it goes</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Revstake <span class="fact-table__note">Base</span></th>
              <td data-label="Fee paid in">REGENT or the Revstake token, depending on the trade</td>
              <td data-label="Where it goes">
                1% sent to Regent. 2% added to the token's staking rewards.
              </td>
            </tr>
            <tr>
              <th scope="row">Memestake <span class="fact-table__note">Base</span></th>
              <td data-label="Fee paid in">The paired stock, buying or selling</td>
              <td data-label="Where it goes">
                {memestake_fees(:base, "swapped to USDC and paid into REGENT staking")}
              </td>
            </tr>
            <tr>
              <th scope="row">
                Memestake <span class="fact-table__note">Robinhood Chain</span>
              </th>
              <td data-label="Fee paid in">The paired stock, buying or selling</td>
              <td data-label="Where it goes">
                {memestake_fees(
                  :robinhood,
                  "swapped to USDG for REGENT staking, held on Robinhood Chain until the transfer to Base is set up"
                )}
              </td>
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
          Revstake auctions are priced in REGENT, and part of what Autolaunch earns is paid into
          REGENT staking. <.link navigate={~p"/regent"}>About REGENT</.link>
        </p>
      </section>

      <details class="fact-more">
        <summary>Show details</summary>
        <ul class="fact-more__body">
          <li>
            Revstake fees come from the side of the trade you did not set: out of what you receive,
            or added to what you pay.
          </li>
          <li>Memestake fees are held in the stock and paid onward after the trade.</li>
          <li>Regent's 2% comes out of staking rewards. It is not another trading fee.</li>
          <li>The rates are fixed in the contracts and cannot be changed.</li>
        </ul>
      </details>
    </main>
    """
  end

  # Where each share of a Memestake trading fee goes on `chain`.
  defp memestake_fees(chain, regent_route),
    do:
      "#{FeeSchedule.lane(chain, :v2, :stakers).rate} added to the token's staking rewards. " <>
        "#{FeeSchedule.lane(chain, :v2, :regent).rate} #{regent_route}. " <>
        "#{FeeSchedule.lane(chain, :v2, :creator).rate} paid to the creator."
end
