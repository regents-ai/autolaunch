defmodule AutolaunchWeb.AccountLive do
  @moduledoc """
  `/account`: the signed-in person's Account on Autolaunch. Signed out, it shows
  the shared signed-out section with the site's own Sign in button, and says
  the sign-in ended when it lapsed while the page was open. Signed in, its
  Profile section says who is signed in, with which wallet, links to their
  Regents account and offers Sign out. The agents they paired follow, read-only:
  pairing is managed on regents.sh. Then their Credits and Points, read-only:
  Autolaunch charges no Credits and Points earning has not opened here. Their
  connected accounts come last, through the Create page's connections
  component, so an account connected here is the same one Create shows.

  Each section is read on its own and shows its own loading and could-not-be-read
  states. A Credits change or a pairing made on any Regent site reads again.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.{Human, System}
  alias AutolaunchWeb.Read
  alias RegentAgents.{Harness, Person}

  @reads [:agents_read, :credits_read, :history_read, :points_read]

  @regents_account_url "https://regents.sh/account"

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/account"))
     |> assign(regents_account_url: @regents_account_url)
     |> assign(Map.new(@reads, &{&1, %Read{}}))
     |> listen()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, read_account(socket)}

  # The session hook re-reads the lease before a result lands here, and a
  # lapsed one never reaches this page (`AutolaunchWeb.Live.Session`).
  def handle_async({Read, _, _} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  def handle_info(:credits_changed, socket),
    do: {:noreply, socket |> read_credits() |> read_history("")}

  def handle_info(:agents_changed, socket), do: {:noreply, read_agents(socket)}

  def handle_event("credits_history", %{"after" => cursor}, socket) do
    {:noreply, read_history(socket, cursor)}
  end

  def handle_event("refresh_x_connections", _params, socket) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "account-connections",
      current_human_id: current_human_id(socket.assigns.access_context),
      session_lease: socket.assigns.session_lease
    )

    {:noreply, socket}
  end

  def render(assigns) do
    assigns = assign(assigns, :current_human_id, current_human_id(assigns.access_context))

    ~H"""
    <article class="autolaunch-account-page">
      <header class="autolaunch-heading">
        <h1>Account</h1>
      </header>
      <Regent.Account.signed_out
        :if={!@current_human_id}
        id="account-signed-out"
        reason={@signed_out_reason}
      >
        <:sign_in>
          <Regent.Primitives.button type="button" data-account-target="sign-in">
            Sign in
          </Regent.Primitives.button>
        </:sign_in>
      </Regent.Account.signed_out>
      <section
        :if={@current_human_id}
        class="market-profile-panel autolaunch-account-profile"
        aria-labelledby="account-profile-title"
      >
        <h2 id="account-profile-title">Profile</h2>
        <dl class="autolaunch-account">
          <dt>Signed in as</dt>
          <dd>{@account_control.label}</dd>
          <dt>Wallet</dt>
          <dd>{@account_control.wallet_address}</dd>
        </dl>
        <p>Manage your account and agent pairings on regents.sh</p>
        <div class="autolaunch-account__actions">
          <a
            class="rg-button rg-button--primary"
            href={@regents_account_url}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Open regents.sh in a new tab"
          >
            Open regents.sh <span aria-hidden="true">↗</span>
          </a>
          <Regent.Primitives.button
            type="button"
            variant="secondary"
            data-account-target="sign-out"
          >
            Sign out
          </Regent.Primitives.button>
        </div>
      </section>
      <Regent.Account.agents
        :if={@current_human_id}
        id="account-agents"
        agents={agent_rows(@agents_read)}
      >
        <:about>
          A paired agent can read your positions, balances and Points, and edit the words on
          your launch drafts. It can never use your wallet, bid or start a launch.
        </:about>
        <:footer>
          <a href={@regents_account_url} target="_blank" rel="noopener noreferrer">
            Pair or unpair agents on regents.sh <span aria-hidden="true">↗</span>
          </a>
        </:footer>
      </Regent.Account.agents>
      <div :if={@current_human_id} class="autolaunch-account-balances">
        <Regent.Account.credits_summary
          id="account-credits"
          available={
            @credits_read.value && RegentCredits.Amount.format(@credits_read.value.available)
          }
          held={@credits_read.value && RegentCredits.Amount.format(@credits_read.value.held)}
          state={read_state(@credits_read)}
        />
        <Regent.Account.points_summary
          id="account-points"
          confirmed={
            @points_read.value && RegentPoints.Amount.format(@points_read.value.balance_micro)
          }
          today={
            @points_read.value && RegentPoints.Amount.format(@points_read.value.earned_today_micro)
          }
          pending={@points_read.value && to_string(@points_read.value.pending)}
          state={read_state(@points_read)}
        />
        <section>
          <Regent.Account.history
            id="account-credits-history"
            title="Credits activity"
            rows={credits_rows(@history_read)}
            state={read_state(@history_read)}
            empty_message="No Credits activity yet."
          />
          <Regent.Primitives.button
            :if={@history_read.value && @history_read.value.more?}
            variant="secondary"
            phx-click="credits_history"
            phx-value-after={@history_read.value.next}
          >Older activity</Regent.Primitives.button>
          <Regent.Primitives.button
            :if={@history_read.owner && elem(@history_read.owner, 1) != ""}
            variant="secondary"
            phx-click="credits_history"
            phx-value-after=""
          >Latest activity</Regent.Primitives.button>
        </section>
        <section>
          <Regent.Account.history
            id="account-points-history"
            title="Points activity"
            rows={points_rows(@points_read)}
            state={read_state(@points_read)}
            empty_message="No confirmed Points activity yet."
          />
          <p :if={@points_read.value && @points_read.value.more?}>Showing the latest 50 entries.</p>
          <p>Earning hasn’t opened on Autolaunch yet.</p>
        </section>
      </div>
      <.live_component
        :if={@current_human_id}
        module={AutolaunchWeb.CreatorConnectionsComponent}
        id="account-connections"
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </article>
    """
  end

  defp listen(socket) do
    with true <- connected?(socket),
         {:human, account} <- socket.assigns.access_context.principal do
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, RegentCredits.topic(account.privy_user_id))
      Phoenix.PubSub.subscribe(Autolaunch.PubSub, RegentAgents.topic(account.privy_user_id))
    end

    socket
  end

  defp read_account(socket) do
    socket |> read_agents() |> read_credits() |> read_history("") |> read_points()
  end

  defp read_agents(socket) do
    with_person(socket, fn account ->
      Read.start(socket, :agents_read, account.privy_user_id, fn ->
        RegentAgents.list_my_agents(actor: %Person{privy_user_id: account.privy_user_id})
      end)
    end)
  end

  defp read_credits(socket) do
    with_person(socket, fn account ->
      Read.start(socket, :credits_read, account.privy_user_id, fn ->
        {:ok, RegentCredits.balance(account.privy_user_id)}
      end)
    end)
  end

  defp read_points(socket) do
    with_person(socket, fn account ->
      Read.start(socket, :points_read, account.privy_user_id, fn ->
        points_summary(account.privy_user_id)
      end)
    end)
  end

  defp read_history(socket, cursor) do
    with_person(socket, fn account ->
      actor =
        RegentCredits.Actor.person(
          account.privy_user_id,
          account.wallet_addresses,
          "autolaunch"
        )

      args = if cursor == "", do: %{}, else: %{after: cursor}

      Read.start(socket, :history_read, {account.privy_user_id, cursor}, fn ->
        RegentCredits.history(args, actor: actor)
      end)
    end)
  end

  defp with_person(socket, read) do
    case socket.assigns.access_context.principal do
      {:human, account} -> read.(account)
      _signed_out -> clear_reads(socket)
    end
  end

  # Points belong to the shared account, never this site's own account number.
  defp points_summary(privy_user_id) do
    case Accounts.canonical_by_privy_id(privy_user_id, actor: %System{}) do
      {:ok, canonical} when not is_nil(canonical) ->
        RegentPoints.summary(actor: %Human{human_account_id: canonical.id})

      _missing ->
        {:error, :account_unavailable}
    end
  end

  defp clear_reads(socket), do: Enum.reduce(@reads, socket, &Read.clear(&2, &1))

  defp read_state(%Read{state: state}) when state in [:idle, :loading], do: :loading
  defp read_state(%Read{state: :empty}), do: :ready
  defp read_state(%Read{state: state}), do: state

  defp agent_rows(%Read{state: state}) when state in [:idle, :loading], do: :loading
  defp agent_rows(%Read{state: :error}), do: :unavailable
  defp agent_rows(%Read{value: nil}), do: []

  defp agent_rows(%Read{value: agents}) do
    now = DateTime.utc_now()

    Enum.map(
      agents,
      &%{
        id: &1.id,
        name: &1.name,
        harness: Harness.label(&1.harness),
        backed: not is_nil(&1.human_id),
        last_contact_iso: DateTime.to_iso8601(&1.last_contact_at),
        last_contact: RegentFormat.relative_time(&1.last_contact_at, now)
      }
    )
  end

  defp credits_rows(%Read{value: nil}), do: []

  defp credits_rows(%Read{value: page}) do
    Enum.map(page.entries, fn entry ->
      %{
        label: credits_label(entry.operation),
        amount:
          "Available: #{RegentCredits.Amount.format(entry.available_delta)} · Held: #{RegentCredits.Amount.format(entry.held_delta)}",
        occurred_at: Calendar.strftime(entry.at, "%d %b %Y %H:%M UTC")
      }
    end)
  end

  defp points_rows(%Read{value: nil}), do: []

  defp points_rows(%Read{value: summary}) do
    Enum.map(summary.entries, fn entry ->
      actor =
        if entry.actor_kind == "human",
          do: "You",
          else: Map.get(summary.agent_names, entry.actor_id, "Previously connected agent")

      %{
        label: "#{RegentPoints.Rules.label(entry.rule_id)} · #{actor}",
        amount: "#{RegentPoints.Amount.format(entry.points_micro_delta)} points",
        occurred_at: Calendar.strftime(entry.earned_at, "%d %b %Y %H:%M UTC"),
        status: points_status(entry)
      }
    end)
  end

  defp credits_label("purchase:" <> _), do: "Credits purchased"
  defp credits_label("refund:" <> _), do: "Purchase refunded"
  defp credits_label("gift:" <> _), do: "Credits given"
  defp credits_label("attach:" <> _), do: "Credits added to your account"
  defp credits_label("hold:" <> _), do: "Held Credits activity"
  defp credits_label(_), do: "Credits activity"

  defp points_status(%{reversal_of_entry_id: id}) when not is_nil(id), do: "Correction"
  defp points_status(%{points_micro_delta: 0}), do: "Allowance reached"
  defp points_status(_), do: "Confirmed"
end
