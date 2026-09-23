defmodule AutolaunchWeb.TokenDetailsLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  # Every figure here is a fixed contract rule: RegentLBPStrategy and
  # ConditionalVestingEscrowV1 (Revstake supply), StocksPreset and
  # StocksLaunchpadV1 (Memestake supply), RegentFeeHook, StocksFeeHookV1 and
  # RobinhoodFeeHookV1 (fees), SubjectSplitterV1 and MemestockSplitterCore
  # (staking rewards).
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Token details")}

  def render(assigns) do
    ~H"""
    <main class="fact-page">
      <header class="autolaunch-heading">
        <h1>Token details</h1>
        <p>Supply, trading fees and staking rewards for every Autolaunch token.</p>
      </header>

      <section class="fact-page__section" aria-labelledby="token-details-revstake">
        <h2 id="token-details-revstake">
          Revstake supply <span class="fact-page__total">100 billion</span>
        </h2>
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
      </section>

      <section class="fact-page__section" aria-labelledby="token-details-memestake">
        <h2 id="token-details-memestake">
          Memestake supply <span class="fact-page__total">1 billion</span>
        </h2>
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

      <section class="fact-page__section" aria-labelledby="token-details-fees">
        <h2 id="token-details-fees">Trading fees</h2>
        <p>
          Every trade in a token's official pool pays a <strong class="fact-page__hi">0.30%</strong>
          pool fee and two <strong class="fact-page__hi">1%</strong>
          fees.
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
                <span class="fact-table__tag">Not live yet</span>
              </th>
              <td data-label="Fee paid in">The paired stock, buying or selling</td>
              <td data-label="First 1%">Swapped to USDG for Regent</td>
              <td data-label="Second 1%">Added to the token's staking rewards</td>
            </tr>
          </tbody>
        </table>
        <p>
          The <strong class="fact-page__hi">0.30%</strong>
          pool fee goes to liquidity providers. What each launch's locked liquidity earns is added to
          its staking rewards.
        </p>
      </section>

      <section class="fact-page__section" aria-labelledby="token-details-staking">
        <h2 id="token-details-staking">Staking rewards</h2>
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
