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
        <p>The auction, supply, trading fees and staking rewards for new v2 launches.</p>
      </header>

      <section class="fact-page__section" aria-labelledby="how-it-works-auction">
        <h2 id="how-it-works-auction">How the auction works</h2>
        <p>
          Every Autolaunch token is sold in a continuous clearing auction (CCA). CCA is the ideal
          auction model for quality projects and teams to bootstrap liquidity, with healthy market
          behavior and true price discovery.
        </p>
        <h3 class="fact-page__subhead">A simple mental model</h3>
        <ul class="fact-page__list">
          <li>Buyers specify their total budget and max price they would pay for a token.</li>
          <li>
            Orders are spread across all remaining blocks and executed over time (like a TWAP).
          </li>
          <li>
            The auction starts at a floor price and goes up over time, with each block clearing at
            the highest price where demand exceeds supply.
          </li>
          <li>
            Each block where the clearing price is lower than your max price, you will receive
            tokens for a portion of your budget. If your max price is exceeded, the remainder of
            your TWAP is cancelled.
          </li>
        </ul>
        <h3 class="fact-page__subhead">Why the price moves</h3>
        <ul class="fact-page__list">
          <li>Every CCA bid is split across all blocks for the remaining auction.</li>
          <li>
            So the price stays at the floor until there is enough demand to buy out the entire
            auction at the floor or higher.
          </li>
          <li>
            At that point every bid above the floor pushes the clearing price up, again spread
            across all remaining blocks. There is enough demand to buy out the rest of the auction
            at this higher price.
          </li>
          <li>So: simple supply and demand.</li>
        </ul>
        <h3 class="fact-page__subhead">What is the game theory?</h3>
        <ul class="fact-page__list">
          <li>Bid early with your real max budget and your real max price.</li>
          <li>
            Your max price ensures you will not buy a single token above what you are willing to
            pay, and orders TWAP over the remaining duration, so waiting only gets you a worse
            average price.
          </li>
          <li>
            With a well parameterized auction (not too fast), there are no crazy timing games,
            sniping, bundling, sandwiching, etc.
          </li>
          <li>Everyone has equal access to buying at the same rates.</li>
          <li>No advantages for advanced users or MEV bots.</li>
          <li>Just real price discovery.</li>
        </ul>
        <p>
          Even if you bid $10b FDV on the first day, you would not have overpaid, and instead
          executed at a DCA price between floor and clearing.
        </p>
        <p>
          After a successful auction, a large portion of the auction proceeds and reserve of tokens
          is used to seed a Uniswap v4 pool.
        </p>
      </section>

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
                Released to the launch's treasury over <strong>365 days from graduation</strong>,
                with the unpaired reserve and auction rounding leftovers. The treasury also receives at least half the
                REGENT raised.
              </td>
            </tr>
          </tbody>
        </table>
        <p>
          Every v2 auction opens at the lowest price it accepts. Its minimum is the whole sale
          allocation at that floor, rounded up, about a billionth of a REGENT. The launcher chooses
          neither. A successful auction sells the whole allocation, apart from rounding. If it
          misses its minimum, every bidder takes back their full bid and all 100 billion tokens
          are retired to the dead address.
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
          Memestake launches last 24 hours. 49.75% of the tokens are sold in the auction, 49.75% is
          reserved for the locked trading pool, and 0.5% goes to the token's creator over 30 days
          from graduation. Stakers earn the onchain stock from fees.
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
                <strong>497.5 million (49.75%)</strong>
              </td>
              <td data-label="After a successful auction">
                Winning bidders claim what they bought.
              </td>
            </tr>
            <tr>
              <th scope="row">Liquidity reserve</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong>497.5 million (49.75%)</strong>
              </td>
              <td data-label="After a successful auction">
                The full-range position pairs the stock raised with the tokens it needs at the
                auction's final clearing price. Remaining reserve is locked in a token-only position
                above the opening token price. Both positions are locked forever; stock rounding
                dust goes to the protocol fee lane.
              </td>
            </tr>
            <tr>
              <th scope="row">Creator</th>
              <td data-label="Amount" class="fact-table__amount">
                <strong>5 million (0.5%)</strong>
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
          Every v2 auction opens at the lowest price it accepts. Its minimum is the whole sale
          allocation at that floor, rounded up; the launcher chooses neither. A successful auction
          sells the whole allocation, apart from rounding. If it misses its minimum, every bidder
          takes back their full bid and all 1 billion tokens, including the creator allocation, are
          retired to the dead address. After graduation, token rounding leftovers are also retired.
        </p>
        <p>
          The four existing v1 Memestake auctions (BITE, JollyB, AGI and RDOG) keep their original
          terms: 80% offered in the auction, 20% reserved for liquidity, no creator allocation,
          and a 1% hook fee each to Regent and the token's staking contract. New v1 launches are paused;
          existing withdrawals, claims, trading and staking remain supported.
        </p>
      </section>

      <section class="fact-page__section" aria-labelledby="how-it-works-fees">
        <h2 id="how-it-works-fees">Trading fees</h2>
        <p>
          V2 Revstake trades pay a 3% hook fee: <strong class="fact-page__hi">2%</strong>
          enters the launch's revenue splitter and <strong class="fact-page__hi">1%</strong>
          goes to Regent.
          REGENT collected in that 1% goes directly to REGENT staking; launch tokens go to the Regent Safe. Use
          <a href="https://regents.sh/stake">regents.sh/stake</a>
          to participate. V2 Memestake trades pay a 4.3% hook fee on the gross stock side, shared by the memestakers
          (<strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :stakers).rate}</strong>), REGENT stakers (<strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :regent).rate}</strong>) and the token's creator (<strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :creator).rate}</strong>). The trading pool also charges the standard <strong class="fact-page__hi">{FeeSchedule.lane(:base, :v2, :pool).rate}</strong>, and what the locked liquidity earns from it enters the token’s revenue splitter.
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
                1% sent directly to REGENT staking when paid in REGENT, or to the Regent Safe
                when paid in the launch token. 2% enters the launch's revenue splitter.
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
        <p>
          What each launch's locked liquidity earns enters its revenue splitter. Each v2 hook
          rounds the total fee once and assigns the rounding remainder to the launch's splitter
          share after calculating the other lanes.
        </p>
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
          <li>
            Anyone can settle Memestake creator and token-staker fees. Protocol conversion requires
            the authorized executor. Creator fees always pay the original launcher in stock.
          </li>
          <li>Regent's 2% comes out of staking rewards. It is not another trading fee.</li>
          <li>Retired tokens remain in reported total supply; they are held at the dead address.</li>
          <li>The rates are fixed in the contracts and cannot be changed.</li>
        </ul>
      </details>
    </main>
    """
  end

  # Where each share of a Memestake trading fee goes on `chain`.
  defp memestake_fees(chain, regent_route),
    do:
      "#{FeeSchedule.lane(chain, :v2, :stakers).rate} enters the token’s staking splitter. " <>
        "#{FeeSchedule.lane(chain, :v2, :regent).rate} #{regent_route}. " <>
        "#{FeeSchedule.lane(chain, :v2, :creator).rate} paid to the creator."
end
