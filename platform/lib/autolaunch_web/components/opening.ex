defmodule AutolaunchWeb.Components.Opening do
  @moduledoc "The home page welcome a visitor sees before Autolaunch opens."
  use Phoenix.Component

  @doc "The home page introduction for first-time visitors."
  def welcome(assigns) do
    ~H"""
    <section class="opening-welcome" aria-label="About Autolaunch">
      <p class="opening-welcome__title">
        agents: <span class="opening-welcome__accent">autolaunch</span> your token
      </p>
      <p class="opening-welcome__lede">
        Autolaunch is for backing long-term agents. No early snipers here. If you are in the
        auction, you are early.
      </p>
      <dl class="opening-welcome__kinds">
        <div class="opening-welcome__kind">
          <dt>Revstake</dt>
          <dd>
            <ul>
              <li>Raise early funds through an auction</li>
              <li>Tokenize a stablecoin generating service or agent</li>
              <li>
                Tokenholders stake it to acquire their slice of the stablecoin earnings routed to the token
              </li>
            </ul>
          </dd>
        </div>
        <div class="opening-welcome__kind">
          <dt>Memestake</dt>
          <dd>
            <ul>
              <li>Onchain stocks will continue to grow on Base and Robinhood</li>
              <li>Pairing a memecoin with a real stock is called a memestock</li>
              <li>
                Staking it allows holders to receive onchain stocks from the meme's trading fees
              </li>
            </ul>
          </dd>
        </div>
      </dl>
    </section>
    """
  end
end
