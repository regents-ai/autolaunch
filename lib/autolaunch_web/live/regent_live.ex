defmodule AutolaunchWeb.RegentLive do
  @moduledoc false

  use AutolaunchWeb, :live_view

  alias Autolaunch.RegentFacts
  alias AutolaunchWeb.TokenDisplay

  def mount(_params, _session, socket) do
    {:ok,
     assign_async(socket, :facts, fn ->
       case RegentFacts.read() do
         {:ok, facts} -> {:ok, %{facts: facts}}
         {:error, reason} -> {:error, reason}
       end
     end)}
  end

  def render(assigns) do
    ~H"""
    <main class="regent-page">
      <h1>REGENT</h1>

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
      <p :if={@facts.ok?} id="regent-block">Read at block {@facts.result.block_number}</p>

      <p :if={@facts.failed} id="regent-unavailable" class="regent-status">
        REGENT facts are unavailable right now.
      </p>

      <p>Every Autolaunch auction is quoted in REGENT.</p>

      <nav class="regent-links">
        <.link id="regent-stake" href="https://regents.sh/stake">Stake REGENT</.link>
        <.link id="regent-redeem" href="https://regents.sh/redeem">Redeem</.link>
      </nav>
    </main>
    """
  end
end
