defmodule AutolaunchWeb.PointsLive do
  @moduledoc """
  `/account/points`: the signed-in person's Points, the template's page. The
  balance and recent activity come from the shared Points ledger under their
  Regents account, never this site's own account number. The NFT bonus tier is
  read from Base once per page open, against the same per-account allowance as
  the wallet reads. What earns points follows; until earning opens it names the
  ways to earn with no amounts.
  """
  use AutolaunchWeb, :live_view

  alias Autolaunch.Actors.Human
  alias AutolaunchWeb.Read
  alias RegentPoints.{Amount, Rules}

  def mount(_params, _session, socket) do
    tracked = Rules.tracked()

    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/account/points"))
     |> assign(
       account_id: account_id(socket.assigns.access_context),
       points: %Read{},
       bonus: %Read{},
       earning: Rules.active(),
       daily: daily(tracked),
       once: once(tracked),
       apps: apps(tracked)
     )
     |> listen()}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, socket |> read_points() |> read_bonus()}

  # The session hook re-reads the lease before a result lands here, and a
  # lapsed one never reaches this page (`AutolaunchWeb.Live.Session`).
  def handle_async({Read, _, _} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  # A points award or correction landed for this account.
  def handle_info(%{topic: "points:" <> _}, socket), do: {:noreply, read_points(socket)}

  def render(assigns) do
    assigns = assign(assigns, :signed_in?, signed_in?(assigns.access_context))

    ~H"""
    <article id="points-page" class="account-page">
      <header class="autolaunch-heading">
        <h1>
          Points
          <Regent.Primitives.tip id="points-about" label="About Points">
            What you and your paired agents earn here, counted in one account.
          </Regent.Primitives.tip>
        </h1>
      </header>
      <Regent.Account.signed_out
        :if={!@signed_in?}
        id="points-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>
      <AutolaunchWeb.Components.Loading.placeholder
        :if={@signed_in? && is_nil(@points.value) && @points.state in [:idle, :loading]}
        label="Reading your points"
      />
      <Regent.Primitives.notice :if={@points.state == :error} tone="error">
        Points could not be read. Try refreshing this page.
      </Regent.Primitives.notice>
      <div :if={@signed_in? && @points.value} class="account-grid">
        <Regent.Account.points_summary
          id="account-points-summary"
          title="Balance"
          confirmed={Amount.format(@points.value.balance_micro)}
          today={Amount.format(@points.value.earned_today_micro)}
          pending={to_string(@points.value.pending)}
          state={summary_state(@points.state)}
          allowances={
            Enum.map(
              if(@earning == [], do: [], else: @points.value.allowances),
              &%{label: scope_name(&1.scope), value: "#{Amount.format(&1.remaining)} remaining"}
            )
          }
        />
        <section class="account-panel account-details">
          <h2>
            Your bonus
            <Regent.Primitives.tip id="points-bonus-about" label="About your points bonus">
              Animata I, Animata II and Regents Club count across your verified linked wallets.
              At the end of each 30-day period, the tier your wallets hold that day adds its
              bonus to the points you earned in that period, one-time awards included.
            </Regent.Primitives.tip>
          </h2>
          <p :if={@bonus.state in [:idle, :loading]} role="status">Checking your NFTs…</p>
          <p :if={@bonus.state in [:error, :stale]}>
            Your NFTs could not be checked. Try refreshing this page.
          </p>
          <dl :if={@bonus.state == :ready}>
            <div>
              <dt>NFTs held</dt>
              <dd>{@bonus.value.nft_count}</dd>
            </div>
            <div>
              <dt>Bonus this period</dt>
              <dd>+{@bonus.value.percent}%</dd>
            </div>
          </dl>
          <dl :if={@points.value.period_bonuses != []}>
            <div :for={period <- @points.value.period_bonuses}>
              <dt>Period {period.period}</dt>
              <dd>
                +{Amount.format(period.bonus_micro)} ({period.nft_count} NFTs, +{period.bonus_percent}%)
              </dd>
            </div>
          </dl>
        </section>
        <section class="account-panel">
          <h2>Recent points activity</h2>
          <p :if={@points.value.entries == []}>No confirmed points activity yet.</p>
          <ol>
            <li :for={entry <- @points.value.entries}>
              <p>{Rules.label(entry.rule_id)} · {actor_name(entry, @points.value.agent_names)}</p>
              <p>{Amount.format(entry.points_micro_delta)} points</p>
              <Regent.Primitives.tip
                :if={entry.cap_reduction_micro > 0}
                id={"points-cap-#{entry.id}"}
                label="About this award’s allowance"
              >
                {Amount.format(entry.points_micro_delta + entry.cap_reduction_micro)} before limits; {Amount.format(
                  entry.points_micro_delta
                )} awarded. {Amount.format(entry.cap_reduction_micro)} exceeded the daily or per-action allowance.
              </Regent.Primitives.tip>
              <p>
                {entry_status(entry)} · {Calendar.strftime(entry.earned_at, "%d %b %Y %H:%M UTC")}
              </p>
            </li>
          </ol>
          <p :if={@points.value.more?}>Showing the latest 50 entries.</p>
        </section>
      </div>
      <section id="points-earn" class="account-panel points-earn">
        <h2>What earns points</h2>
        <p :if={@earning == []} role="status">Earning hasn’t opened yet.</p>
        <h3 :if={@daily != []}>Every day</h3>
        <.ways :if={@earning == []} rules={@daily} />
        <table :if={@earning != [] and @daily != []} class="points-table">
          <thead>
            <tr>
              <th scope="col">Action</th><th scope="col">Points</th><th scope="col">Limit</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @daily}>
              <th scope="row">
                {Rules.label(rule["id"])}<.not_yet rule={rule} earning={@earning} />
              </th>
              <td>{points(rule)}</td>
              <td>{limit(rule)}</td>
            </tr>
          </tbody>
        </table>
        <h3 :if={@once != []}>Once</h3>
        <.ways :if={@earning == []} rules={@once} />
        <table :if={@earning != [] and @once != []} class="points-table">
          <thead>
            <tr>
              <th scope="col">Action</th><th scope="col">Points</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={rule <- @once}>
              <th scope="row">
                {Rules.label(rule["id"])}<.not_yet rule={rule} earning={@earning} />
              </th>
              <td>{points(rule)}</td>
            </tr>
          </tbody>
        </table>
        <div class="account-details points-earn__notes">
          <div :if={@earning != [] and @apps != []}>
            <h3>Daily limits</h3>
            <dl>
              <div>
                <dt>You</dt>
                <dd>Up to {whole(Rules.daily_cap("activity:human"))} a day on {names(@apps)}</dd>
              </div>
              <div>
                <dt>Your agents, together</dt>
                <dd>Up to {whole(Rules.daily_cap("activity:agent"))} a day on {names(@apps)}</dd>
              </div>
            </dl>
          </div>
          <div>
            <h3>NFT bonus</h3>
            <p>
              Animata I, Animata II and Regents Club in your linked wallets, counted at the end of each 30-day period. That period’s points get the bonus.
            </p>
            <table :if={@earning != []} class="points-table">
              <thead>
                <tr>
                  <th scope="col">NFTs</th><th scope="col">Bonus</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{nfts, percent} <- tiers()}>
                  <th scope="row">{nfts}</th><td>+{percent}%</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </article>
    """
  end

  attr :rules, :list, required: true

  # Before earning opens, the ways to earn are named with no amounts.
  defp ways(assigns) do
    ~H"""
    <ul :if={@rules != []} class="points-ways">
      <li :for={rule <- @rules}>{Rules.label(rule["id"])}</li>
    </ul>
    """
  end

  attr :rule, :map, required: true
  attr :earning, :list, required: true

  defp not_yet(assigns) do
    ~H"""
    <span :if={@rule not in @earning} class="points-earn__soon">Not yet</span>
    """
  end

  defp account_id(%{principal: {:human, account}}), do: account.id
  defp account_id(_signed_out), do: nil

  defp signed_in?(access_context), do: match?({:human, _}, access_context.principal)

  defp listen(%{assigns: %{account_id: id}} = socket) when not is_nil(id) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, "points:#{id}")
    socket
  end

  defp listen(socket), do: socket

  defp read_points(%{assigns: %{account_id: nil}} = socket) do
    if signed_in?(socket.assigns.access_context),
      do: Read.start(socket, :points, nil, fn -> {:error, :account_unavailable} end),
      else: Read.clear(socket, :points)
  end

  defp read_points(%{assigns: %{account_id: id}} = socket) do
    Read.start(socket, :points, id, fn ->
      RegentPoints.summary(actor: %Human{human_account_id: id})
    end)
  end

  defp read_bonus(%{assigns: %{account_id: nil}} = socket), do: Read.clear(socket, :bonus)

  # Base is read for the person's NFTs, counted against the same per-account
  # allowance as the wallet reads.
  defp read_bonus(%{assigns: %{account_id: id}} = socket) do
    Read.start(socket, :bonus, id, fn ->
      case Autolaunch.Limits.spend(:wallet_read, {:human, id}) do
        :ok -> RegentPoints.Bonus.current(id)
        :limited -> {:error, :limited}
      end
    end)
  end

  defp daily(rules), do: Enum.filter(rules, &(&1["category"] in ["credits", "activity"]))
  defp once(rules), do: Enum.filter(rules, &(&1["category"] == "milestone"))

  defp points(%{"category" => "credits", "micro_points_per_atomic_usdc" => rate}),
    do: "#{whole(rate * 1_000_000)} per USDC"

  defp points(%{"points" => points}), do: points

  defp limit(%{"category" => "credits", "daily_caps_micro" => caps}),
    do: "Up to #{whole(caps["credits"])} a day"

  defp limit(%{"count" => 1}), do: "Once a day"
  defp limit(%{"count" => 2}), do: "Twice a day"
  defp limit(%{"count" => count}), do: "#{count} times a day"

  defp whole(micro), do: div(micro, Rules.unit())

  defp apps(rules), do: rules |> Rules.daily_apps() |> Enum.map(&String.capitalize/1)

  defp names([name]), do: name

  defp names(names) do
    {last, rest} = List.pop_at(names, -1)
    Enum.join(rest, ", ") <> " and " <> last
  end

  # Ascending tiers, each running up to the next one's minimum.
  defp tiers do
    ascending = Enum.sort(RegentPoints.Bonus.tiers())
    next = Enum.map(Enum.drop(ascending, 1), &elem(&1, 0)) ++ [nil]

    Enum.zip_with(ascending, next, fn
      {minimum, percent}, nil -> {"#{minimum}+", percent}
      {minimum, percent}, upper -> {"#{minimum}–#{upper - 1}", percent}
    end)
  end

  defp actor_name(%{actor_kind: "human"}, _names), do: "You"
  defp actor_name(entry, names), do: Map.get(names, entry.actor_id, "Previously connected agent")

  defp entry_status(%{reversal_of_entry_id: id}) when not is_nil(id), do: "Correction"
  defp entry_status(%{points_micro_delta: 0}), do: "Allowance reached"
  defp entry_status(_), do: "Confirmed"

  defp summary_state(state) when state in [:idle, :loading], do: :loading
  defp summary_state(:empty), do: :ready
  defp summary_state(state), do: state

  defp scope_name("activity:account"), do: "You and your agents"
  defp scope_name("credits"), do: "Credits purchases"
  defp scope_name("activity:human"), do: "Your actions"
  defp scope_name("activity:agent"), do: "Your agents’ actions"
end
