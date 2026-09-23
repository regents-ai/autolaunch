defmodule AutolaunchWeb.TokenDetailsLive do
  @moduledoc false
  use AutolaunchWeb, :live_view

  # Every figure here is a fixed contract rule: RegentFeeHook (Revstake),
  # StocksFeeHookV1 (Base Memestake), RobinhoodFeeHookV1 (Robinhood Memestake),
  # the two LP lockers, SubjectSplitterV1 and MemestockSplitterCore.
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Token details")}

  def render(assigns) do
    ~H"""
    <main class="token-details">
      <header class="autolaunch-heading">
        <h1>Token details</h1>
        <p>
          When an auction ends, its token trades in one official Uniswap pool. Here is what a
          trade there costs and where the fees go.
        </p>
      </header>

      <section class="token-details__section" aria-labelledby="token-details-fee">
        <h2 id="token-details-fee">Trading fee</h2>
        <p class="token-details__headline">
          <span class="token-details__number">2.30%</span>
          <span>on every trade in a token's official pool</span>
        </p>
        <ul class="token-details__parts">
          <li>
            <span class="token-details__part-number">0.30%</span>
            <span>Pool fee, earned by liquidity providers</span>
          </li>
          <li>
            <span class="token-details__part-number">1%</span>
            <span>Regent's share</span>
          </li>
          <li>
            <span class="token-details__part-number">1%</span>
            <span>The token's stakers' share</span>
          </li>
        </ul>
        <p class="token-details__note">
          2.30% is the headline rate. Each part is worked out on its own amount, so a single trade
          can come out slightly different.
        </p>
      </section>

      <section class="token-details__section" aria-labelledby="token-details-shares">
        <h2 id="token-details-shares">Where each 1% goes</h2>
        <table class="token-details__table">
          <thead>
            <tr>
              <th scope="col">Launch</th>
              <th scope="col">Fee is paid in</th>
              <th scope="col">Regent's 1%</th>
              <th scope="col">Stakers' 1%</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Revstake <span class="token-details__chain">Base</span></th>
              <td data-label="Fee is paid in">
                REGENT or the Revstake token, depending on the trade
              </td>
              <td data-label="Regent's 1%">Sent straight to Regent's treasury</td>
              <td data-label="Stakers' 1%">Sent straight to the token's staking rewards</td>
            </tr>
            <tr>
              <th scope="row">Memestake <span class="token-details__chain">Base</span></th>
              <td data-label="Fee is paid in">The paired stock, whether you buy or sell</td>
              <td data-label="Regent's 1%">
                Held in the stock, then swapped to USDC and paid to REGENT stakers
              </td>
              <td data-label="Stakers' 1%">
                Held in the stock, then added to the token's staking rewards
              </td>
            </tr>
            <tr>
              <th scope="row">
                Memestake <span class="token-details__chain">Robinhood Chain</span>
                <span class="token-details__tag">Not live yet</span>
              </th>
              <td data-label="Fee is paid in">The paired stock, whether you buy or sell</td>
              <td data-label="Regent's 1%">
                Held in the stock, then swapped to USDG and paid into Regent's revenue
              </td>
              <td data-label="Stakers' 1%">
                Held in the stock, then added to the token's staking rewards
              </td>
            </tr>
          </tbody>
        </table>
        <p>
          The 0.30% pool fee is separate. Anyone who adds liquidity to the pool earns it. Each
          launch's own liquidity is locked for good, and the fees it earns go to the token's
          staking rewards.
        </p>
      </section>

      <section class="token-details__section" aria-labelledby="token-details-staking">
        <h2 id="token-details-staking">Staking rewards</h2>
        <p>
          Regent keeps 2% of every staking reward that arrives. This comes out of the rewards; it
          is not another trading fee.
        </p>
        <table class="token-details__table token-details__table--compare">
          <thead>
            <tr>
              <th scope="col"><span class="visually-hidden">Rule</span></th>
              <th scope="col">Revstake</th>
              <th scope="col">Memestake</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Regent's share</th>
              <td data-label="Revstake">2%</td>
              <td data-label="Memestake">2%</td>
            </tr>
            <tr>
              <th scope="row">The other 98%</th>
              <td data-label="Revstake">
                Stakers get the part that matches how much of the whole supply is staked. The
                rest goes to the token's treasury.
              </td>
              <td data-label="Memestake">Shared by everyone staking, in proportion to their stake</td>
            </tr>
            <tr>
              <th scope="row">If nobody is staking</th>
              <td data-label="Revstake">The 98% goes to the token's treasury</td>
              <td data-label="Memestake">All 100% goes to Regent</td>
            </tr>
          </tbody>
        </table>
        <p class="token-details__example">
          Example: 100 USDC of rewards arrive for a Revstake token with 40% of its supply staked.
          Regent gets 2, stakers share 39.20 and the token's treasury gets 58.80.
        </p>
      </section>

      <details class="token-details__more">
        <summary>Show details</summary>
        <div class="token-details__more-body">
          <section aria-labelledby="token-details-asset">
            <h3 id="token-details-asset">Which token pays the fee</h3>
            <ul>
              <li>
                Revstake: the two 1% shares are taken from the side of the trade you did not set.
                If you set how much you pay, they come out of what you receive. If you set how much
                you receive, they are added to what you pay. Each 1% is worked out on that side's
                amount before the fee.
              </li>
              <li>
                Memestake: always the paired stock. When you pay in the stock, each 1% is worked out
                on the total stock you pay, fee included. When you receive the stock, each 1% is
                worked out on the stock the pool pays out, before the fee comes off.
              </li>
            </ul>
          </section>

          <section aria-labelledby="token-details-maths">
            <h3 id="token-details-maths">How the numbers are worked out</h3>
            <ul>
              <li>Each 1% is worked out separately and rounded down to the token's smallest unit.</li>
              <li>The 0.30% pool fee is Uniswap's own fee, taken by the pool on what goes in.</li>
              <li>
                Because each part has its own base, 2.30% is a headline rate, not an exact quote for
                any one trade.
              </li>
            </ul>
          </section>

          <section aria-labelledby="token-details-timing">
            <h3 id="token-details-timing">When Memestake fees move</h3>
            <p>
              Both 1% shares are held in the stock when you trade and are paid onward later, in
              separate steps. Regent's share is swapped to USDC on Base, or to USDG on Robinhood
              Chain, at that point.
            </p>
          </section>

          <section aria-labelledby="token-details-locked">
            <h3 id="token-details-locked">Locked liquidity</h3>
            <p>
              The liquidity each launch adds to its pool is locked for good: nobody can withdraw it.
              Anyone can collect the 0.30% fees it earns, and those fees can only go to that token's
              staking rewards.
            </p>
          </section>

          <section aria-labelledby="token-details-rewards">
            <h3 id="token-details-rewards">Staking rewards in full</h3>
            <ul>
              <li>
                Regent's 2% is taken from everything that arrives as staking rewards, including the
                stakers' 1% and the locked liquidity's fees.
              </li>
              <li>
                Revstake: stakers share the other 98% multiplied by the tokens staked, divided by the
                token's whole supply. The token's treasury gets the rest, including any rounding.
              </li>
              <li>
                Memestake: everyone staking at that moment shares the other 98% by stake size. If
                nobody is staking, the whole amount goes to Regent.
              </li>
            </ul>
          </section>

          <section aria-labelledby="token-details-fixed">
            <h3 id="token-details-fixed">Fixed rules</h3>
            <p>
              These rates are written into the contracts. Once a pool is set up, nobody can change
              its fees or send a token's staking share anywhere else.
            </p>
          </section>

          <section aria-labelledby="token-details-robinhood">
            <h3 id="token-details-robinhood">Robinhood Chain</h3>
            <p>
              Memestake on Robinhood Chain is not live yet. Its row above shows how its contracts
              are written.
            </p>
          </section>
        </div>
      </details>
    </main>
    """
  end
end
