defmodule AutolaunchWeb.Components.RevenueHistory do
  @moduledoc """
  A Revstake token's revenue history on its page: each payment its splitter
  recognized, newest first, with its amount in its own asset, the day it
  landed and a link to its transaction. Amounts are exact, as the splitter
  counted them, with their thousands grouped. The rows settle in one after another
  as they arrive (`MotionCascade`). Read only: nothing here asks a wallet.
  """
  use Phoenix.Component

  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.Components.BidPlaced
  alias AutolaunchWeb.Motion
  alias Phoenix.LiveView.AsyncResult

  attr :revenue, AsyncResult, required: true, doc: "the token's recorded revenue, newest first"

  def revenue_history(assigns) do
    ~H"""
    <section class="revenue-history" aria-labelledby="revenue-history-title">
      <h2 id="revenue-history-title">Revenue history</h2>
      <p :if={@revenue.loading} class="revenue-history__note" role="status">Reading revenue…</p>
      <p :if={@revenue.failed} class="revenue-history__note" role="status">
        Revenue can't be shown right now.
      </p>
      <p :if={@revenue.ok? && @revenue.result == []} class="revenue-history__note">
        No revenue has reached this token's stakers yet.
      </p>
      <ol
        :if={@revenue.ok? && @revenue.result != []}
        id="revenue-history-rows"
        class="revenue-history__rows"
        phx-hook="MotionCascade"
        data-variant={Motion.standard("grid")}
      >
        <li :for={row <- @revenue.result}>
          <strong>{amount(row.amount)} <span>{row.asset_symbol}</span></strong>
          <time datetime={DateTime.to_iso8601(row.occurred_at)}>
            {Calendar.strftime(row.occurred_at, "%-d %b %Y")}
          </time>
          <a
            href={BidPlaced.transaction_url(:base, row.transaction_hash)}
            target="_blank"
            rel="noopener noreferrer"
          >
            Transaction <span aria-hidden="true">↗</span>
          </a>
        </li>
      </ol>
    </section>
    """
  end

  defp amount(amount),
    do: amount |> Decimal.normalize() |> Decimal.to_string(:normal) |> Amounts.grouped()
end
