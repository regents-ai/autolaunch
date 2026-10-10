defmodule AutolaunchWeb.ProfileLive do
  @moduledoc """
  `/profile`: the signed-in person's account on Autolaunch: who is signed in,
  with which wallet, their connected accounts and a way to log out, plus the
  way to their Regents account, where pairings with agents are managed. The
  connected accounts reuse the Create page's connections component, so an
  account connected here is the same one Create shows.
  """
  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias Autolaunch.{AccessContext, Accounts}
  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.{Human, System}
  alias AutolaunchWeb.Read

  @reads [:credits_read, :history_read, :points_read]

  @regents_account_url "https://regents.sh/account"

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/profile"))
     |> assign(
       current_human_id: current_human_id(socket.assigns.access_context),
       account: AccessContext.account_control(socket.assigns.access_context),
       regents_account_url: @regents_account_url,
       credits_read: %Read{},
       history_read: %Read{},
       points_read: %Read{}
     )}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, read_account(socket)}

  def handle_async({Read, _, _} = name, result, socket) do
    with %{lineage: lineage, account_id: id} <- socket.assigns.session_lease,
         {:ok, account} when not is_nil(account) <- read_leased_account(lineage, id),
         {:human, current} <- socket.assigns.access_context.principal,
         true <- account.privy_user_id == current.privy_user_id do
      {:noreply, Read.settle(socket, name, result)}
    else
      {:error, :session_unavailable} -> {:noreply, unavailable_reads(socket)}
      _ -> {:noreply, socket |> clear_reads() |> assign(current_human_id: nil)}
    end
  end

  def handle_event("credits_history", %{"after" => cursor}, socket) do
    {:noreply, read_history(socket, cursor)}
  end

  def handle_event("refresh_x_connections", _params, socket) do
    send_update(AutolaunchWeb.CreatorConnectionsComponent,
      id: "profile-connections",
      current_human_id: socket.assigns.current_human_id,
      session_lease: socket.assigns.session_lease
    )

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <section class="autolaunch-profile-page">
      <section class="market-profile-panel autolaunch-heading" aria-label="Profile">
        <h1>Profile</h1>
        <p :if={!@current_human_id}>Sign in to see your account.</p>
        <Regent.Primitives.button
          :if={!@current_human_id}
          type="button"
          class="autolaunch-profile-page__sign-in"
          data-account-target="sign-in"
        >
          Sign in
        </Regent.Primitives.button>
        <dl :if={@current_human_id} class="autolaunch-account">
          <dt>Signed in as</dt>
          <dd>{@account.label}</dd>
          <dt>Wallet</dt>
          <dd>{@account.wallet_address}</dd>
        </dl>
        <p :if={@current_human_id}>Manage your account and agent pairings on regents.sh</p>
        <div :if={@current_human_id} class="autolaunch-account__actions">
          <a
            class="rg-button rg-button--primary"
            href={@regents_account_url}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Go to Account on regents.sh, opens in a new tab"
          >
            Go to Account <span aria-hidden="true">↗</span>
          </a>
          <Regent.Primitives.button
            type="button"
            variant="secondary"
            data-account-target="sign-out"
          >
            Log out
          </Regent.Primitives.button>
        </div>
      </section>
      <div :if={@current_human_id} class="autolaunch-account-balances">
        <Regent.Account.credits_summary
          id="profile-credits"
          available={
            @credits_read.value && RegentCredits.Amount.format(@credits_read.value.available)
          }
          held={@credits_read.value && RegentCredits.Amount.format(@credits_read.value.held)}
          state={read_state(@credits_read)}
        />
        <Regent.Account.points_summary
          id="profile-points"
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
            id="profile-credits-history"
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
            id="profile-points-history"
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
        id="profile-connections"
        current_human_id={@current_human_id}
        session_lease={@session_lease}
      />
    </section>
    """
  end

  defp read_account(socket) do
    case socket.assigns.access_context.principal do
      {:human, account} ->
        socket
        |> Read.start(:credits_read, account.privy_user_id, fn ->
          {:ok, RegentCredits.balance(account.privy_user_id)}
        end)
        |> read_history("")
        |> Read.start(:points_read, account.privy_user_id, fn ->
          read_points(account.privy_user_id)
        end)

      _ ->
        clear_reads(socket)
    end
  end

  defp read_points(privy_user_id) do
    case Accounts.canonical_by_privy_id(privy_user_id, actor: %System{}) do
      {:ok, canonical} when not is_nil(canonical) ->
        RegentPoints.summary(actor: %Human{human_account_id: canonical.id})

      _ ->
        {:error, :account_unavailable}
    end
  end

  defp read_history(socket, cursor) do
    case socket.assigns.access_context.principal do
      {:human, account} ->
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

      _ ->
        clear_reads(socket)
    end
  end

  # The authority's bang read raises database failures directly or as an Ash
  # unknown-read error. Without current authority, discard even saved figures.
  defp read_leased_account(lineage, id) do
    {:ok, SessionAuthority.leased_account(lineage, id)}
  rescue
    _failure in [Postgrex.Error, DBConnection.ConnectionError, Ash.Error.Unknown] ->
      {:error, :session_unavailable}
  end

  defp unavailable_reads(socket) do
    Enum.reduce(@reads, socket, fn name, socket ->
      read = Map.fetch!(socket.assigns, name)

      assign(socket, name, %Read{
        state: :error,
        owner: read.owner,
        generation: read.generation + 1,
        error: :session_unavailable
      })
    end)
  end

  defp clear_reads(socket), do: Enum.reduce(@reads, socket, &Read.clear(&2, &1))
  defp read_state(%Read{state: state}) when state in [:idle, :loading], do: :loading
  defp read_state(%Read{state: :empty}), do: :ready
  defp read_state(%Read{state: state}), do: state

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
