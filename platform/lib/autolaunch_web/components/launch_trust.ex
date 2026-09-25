defmodule AutolaunchWeb.Components.LaunchTrust do
  @moduledoc """
  What a buyer can check about a launch, in two separate parts. "Who's behind
  it": the launching wallet and the accounts its creator proved they own,
  which says who they are and nothing about the project's merits. "The launch
  itself": its contracts, its launch type, how its supply is split and where
  its liquidity stands. Liquidity reads as deposited only once the launch is
  recorded as launched, and as locked only once the pool has been read from
  the chain. Shown on auction and token pages on both chains.
  """
  use Phoenix.Component

  alias Autolaunch.Robinhood.Lab, as: RobinhoodLab
  alias Autolaunch.Stocks.Amounts
  alias AutolaunchWeb.Components.{BidPlaced, MarketCard}

  attr :auction, :map, required: true, doc: "the launch's auction record"

  attr :connections, :map,
    default: nil,
    doc: "the creator's connected accounts; nil while they are still being read"

  attr :pool, :map,
    default: nil,
    doc: "the launched pool as read from the chain, when the page has read it"

  attr :token_path, :string, default: nil, doc: "the launched token's page, from an auction page"

  def launch_trust(assigns) do
    auction = assigns.auction
    chain = if RobinhoodLab.chain?(auction.chain_id), do: :robinhood, else: :base

    assigns =
      assign(assigns,
        chain: chain,
        wallet: auction.creator_address,
        accounts: accounts(assigns.connections),
        website: MarketCard.web_link(auction.website),
        telegram: telegram_link(auction.telegram),
        contracts: contracts(auction, assigns.pool),
        split: split(auction.kind),
        supply: supply(auction.token_supply),
        liquidity: liquidity_state(auction.state, assigns.pool)
      )

    ~H"""
    <div class="launch-trust">
      <section class="launch-trust__block" aria-labelledby="launch-trust-who">
        <h2 id="launch-trust-who">Who's behind it</h2>
        <p class="launch-trust__note">
          A checked account means the creator proved they own it. It is not an endorsement of the project.
        </p>
        <dl class="launch-trust__rows">
          <div :if={@wallet}>
            <dt>Launch wallet</dt>
            <dd>
              <a
                class="autolaunch-exact-value"
                href={BidPlaced.address_url(@chain, @wallet)}
                target="_blank"
                rel="noopener noreferrer"
              >{@wallet}</a>
            </dd>
          </div>
          <div :for={{label, account} <- @accounts || []}>
            <dt>{label}</dt>
            <dd :if={account}>
              <a href={account.url} target="_blank" rel="noopener noreferrer">{account.handle}</a>
              <span class="launch-trust__checked">
                <span aria-hidden="true">✓</span> Ownership checked
              </span>
            </dd>
            <dd :if={!account} class="launch-trust__muted">Not connected</dd>
          </div>
          <div :if={@website}>
            <dt>Website</dt>
            <dd>
              <a href={@website.url} target="_blank" rel="noopener noreferrer nofollow">
                {@website.label}
              </a>
              <span class="launch-trust__muted">Named by the creator, not checked</span>
            </dd>
          </div>
          <div :if={@telegram}>
            <dt>Telegram</dt>
            <dd>
              <a href={@telegram.url} target="_blank" rel="noopener noreferrer nofollow">
                {@telegram.label}
              </a>
              <span class="launch-trust__muted">Named by the creator, not checked</span>
            </dd>
          </div>
        </dl>
        <p :if={!@accounts} class="launch-trust__muted" role="status">
          Reading the creator's connected accounts…
        </p>
      </section>

      <section class="launch-trust__block" aria-labelledby="launch-trust-launch">
        <h2 id="launch-trust-launch">The launch itself</h2>
        <dl class="launch-trust__rows">
          <div>
            <dt>Launch type</dt>
            <dd><strong>{@split.name}</strong> · {@split.about}</dd>
          </div>
        </dl>

        <h3 class="autolaunch-micro">Contracts</h3>
        <dl class="launch-trust__rows">
          <div :for={{label, address} <- @contracts}>
            <dt>{label}</dt>
            <dd>
              <a
                class="autolaunch-exact-value"
                href={BidPlaced.address_url(@chain, address)}
                target="_blank"
                rel="noopener noreferrer"
              >{address}</a>
            </dd>
          </div>
          <div :if={@pool}>
            <dt>Pool</dt>
            <dd class="autolaunch-exact-value">{@pool.pool_id}</dd>
          </div>
        </dl>

        <h3 class="autolaunch-micro">Token supply</h3>
        <dl class="launch-trust__rows">
          <div :if={@supply}>
            <dt>Total supply</dt>
            <dd>{@supply}</dd>
          </div>
          <div :for={{label, amount, after_auction} <- @split.rows}>
            <dt>{label}</dt>
            <dd><strong>{amount}</strong> · {after_auction}</dd>
          </div>
        </dl>
        <p class="launch-trust__note">
          <.link navigate="/how-it-works">How every {@split.name} token is split</.link>
        </p>

        <h3 class="autolaunch-micro">Liquidity</h3>
        <.liquidity
          liquidity={@liquidity}
          split={@split}
          chain={@chain}
          pool={@pool}
          token_path={@token_path}
        />
      </section>
    </div>
    """
  end

  attr :liquidity, :atom, required: true
  attr :split, :map, required: true
  attr :chain, :atom, required: true
  attr :pool, :map, default: nil
  attr :token_path, :string, default: nil

  defp liquidity(%{liquidity: :reserved} = assigns) do
    ~H"""
    <p class="launch-trust__status">Reserved for liquidity, not yet deposited</p>
    <p class="launch-trust__text">
      {@split.reserve} is set aside for the pool. It goes into the pool, and is locked there,
      only after a successful auction.
    </p>
    <p class="launch-trust__note">
      Uniswap shows only what is already in a pool, so it shows nothing for this token until then.
    </p>
    """
  end

  defp liquidity(%{liquidity: :none} = assigns) do
    ~H"""
    <p class="launch-trust__status">Not deposited</p>
    <p class="launch-trust__text">
      The auction did not launch, so no pool was opened.
    </p>
    """
  end

  defp liquidity(%{liquidity: :deposited} = assigns) do
    ~H"""
    <p class="launch-trust__status">Deposited when the auction launched</p>
    <p class="launch-trust__text">
      Whether it is locked shows here once the pool has been read.
      <.link :if={@token_path} navigate={@token_path}>See it on the token's page</.link>
    </p>
    <.uniswap_note split={@split} />
    """
  end

  defp liquidity(%{liquidity: :read} = assigns) do
    ~H"""
    <p class="launch-trust__status">
      {if Enum.all?(@pool.positions, & &1.locked?),
        do: "Deposited and locked",
        else: "Deposited, not all of it locked"}
    </p>
    <ul class="launch-trust__positions">
      <li :for={position <- @pool.positions}>
        {amount(position.token_amount)} {@pool.token.symbol} and {amount(position.currency_amount)} {@pool.currency.symbol} deposited
        <span :if={position.locked?} class="launch-trust__muted">
          · locked forever in the locker above
        </span>
        <span :if={!position.locked?} class="launch-trust__muted">
          · held by <a
            class="autolaunch-exact-value"
            href={BidPlaced.address_url(@chain, position.owner)}
            target="_blank"
            rel="noopener noreferrer"
          >{position.owner}</a>, not the locker
        </span>
      </li>
    </ul>
    <.uniswap_note split={@split} />
    """
  end

  attr :split, :map, required: true

  defp uniswap_note(assigns) do
    ~H"""
    <p class="launch-trust__note">
      Uniswap shows the pool as it is now. Trades move the amounts on each side, other people
      can add their own liquidity, and any reserve the pool did not need {@split.unused}, so
      Uniswap's numbers can differ from the reserve above.
    </p>
    """
  end

  # Each account kind the creator could connect, with the matching accounts
  # or nil for a kind they have not connected; Company X only when there is one.
  # A creator's Telegram community as a link and its t.me label.
  defp telegram_link("https://" <> label = url), do: %{url: url, label: label}
  defp telegram_link(_url), do: nil

  defp accounts(nil), do: nil

  defp accounts(connections) do
    connected = MarketCard.connection_list(connections)

    Enum.flat_map(["X", "Company X", "ENS", "GitHub"], fn label ->
      case {label, Enum.filter(connected, &(&1.label == label))} do
        {"Company X", []} -> []
        {label, []} -> [{label, nil}]
        {label, matching} -> Enum.map(matching, &{label, &1})
      end
    end)
  end

  # The launch's own contracts the record names, then the locker that holds
  # its pool position once the pool has been read.
  defp contracts(auction, pool) do
    treasury = if auction.kind == :agent, do: auction.treasury_address

    lockers =
      for %{locked?: true, owner: owner} <- (pool && pool.positions) || [],
          uniq: true,
          do: {"Locker", owner}

    Enum.filter(
      [
        {"Token", auction.token_address},
        {"Auction", auction.auction_address},
        {"Treasury", treasury}
      ],
      fn {_label, address} -> is_binary(address) end
    ) ++ lockers
  end

  # Each launch type's fixed split, as the How Autolaunch works page states it.
  defp split(:agent),
    do: %{
      name: "Revstake",
      about: "stakers share the revenue the project sends through its contract",
      reserve: "Up to 5 billion tokens (5%)",
      unused: "went to the treasury",
      rows: [
        {"Sold in the auction", "Up to 10 billion (10%)",
         "winning bidders claim what they bought"},
        {"Reserved for liquidity", "Up to 5 billion (5%)",
         "paired with REGENT in a permanently locked position"},
        {"Treasury", "85 billion (85%)",
         "released over 365 days, with any unsold auction tokens and unused reserve"}
      ]
    }

  defp split(:stocks),
    do: %{
      name: "Memestake",
      about: "stakers earn the onchain stock from trading fees",
      reserve: "Up to 200 million tokens (20%)",
      unused: "was burned",
      rows: [
        {"Sold in the auction", "Up to 800 million (80%)",
         "winning bidders claim what they bought; unsold tokens are burned"},
        {"Reserved for liquidity", "Up to 200 million (20%)",
         "paired with the stock raised in a permanently locked position; any unused reserve is burned"},
        {"Creator, team or treasury", "0", "no token allocation"}
      ]
    }

  defp amount(value), do: value |> Amounts.compact_decimal() |> Amounts.grouped()

  defp supply(%Decimal{} = supply),
    do: supply |> Decimal.normalize() |> Decimal.to_string(:normal) |> Amounts.grouped()

  defp supply(nil), do: nil

  defp liquidity_state(:graduated, %{positions: [_ | _]}), do: :read
  defp liquidity_state(:graduated, _pool), do: :deposited
  defp liquidity_state(:failed, _pool), do: :none
  defp liquidity_state(_state, _pool), do: :reserved
end
