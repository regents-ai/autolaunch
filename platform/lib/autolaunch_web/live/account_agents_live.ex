defmodule AutolaunchWeb.AccountAgentsLive do
  @moduledoc """
  `/account/agents`: the signed-in person's Agents page, in the layout every Regent
  site shares (`Regent.Account.agents_layout`): the agents they paired, then the box
  to pair another (`AutolaunchWeb.PairingBox`, the section the account menu's Pair
  New Agent leads to, `#account-pairing`). Signed out, it shows the shared
  signed-out section with the site's own Sign in button, and says the sign-in ended
  when it lapsed while the page was open. Unpairing is on regents.sh.

  The agents are read on their own and show their own loading and could-not-be-read
  states. An agent pairing, checking in or unpairing on any Regent site
  (`AutolaunchWeb.Live.Agents`) reads them again.
  """

  use AutolaunchWeb, :live_view

  import AutolaunchWeb.Components.AutolaunchHelpers, only: [current_human_id: 1]

  alias AutolaunchWeb.Read
  alias RegentAgents.{Harness, Person}

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(AutolaunchWeb.PublicDocuments.page("/account/agents"))
     |> assign(agents_read: %Read{})}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, read_agents(socket)}

  # The session hook re-reads the lease before a result lands here, and a
  # lapsed one never reaches this page (`AutolaunchWeb.Live.Session`).
  def handle_async({Read, _, _} = name, result, socket),
    do: {:noreply, Read.settle(socket, name, result)}

  @doc "The agents and this page's pairing box follow an agent change (`AutolaunchWeb.Live.Agents`)."
  def agents_changed(socket) do
    send_update(AutolaunchWeb.PairingBox, id: "account-pairing-box", agents_changed: true)
    read_agents(socket)
  end

  def render(assigns) do
    assigns = assign(assigns, :current_human_id, current_human_id(assigns.access_context))

    ~H"""
    <article class="autolaunch-account-page">
      <header class="autolaunch-heading">
        <h1>Agents</h1>
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
      <Regent.Account.agents_layout :if={@current_human_id} id="account">
        <:agents>
          <Regent.Account.agents id="account-agents" agents={agent_rows(@agents_read)}>
            <:about>
              A paired agent can read your positions, balances and Points, and fill in your launch
              drafts for you to check. It can never use your wallet, bid or start a launch.
            </:about>
            <:footer>
              <a href="https://regents.sh/account#account-agents" class="standalone-link">
                Manage Agents on regents.sh
              </a>
            </:footer>
          </Regent.Account.agents>
        </:agents>
        <:pairing>
          <.live_component
            module={AutolaunchWeb.PairingBox}
            id="account-pairing-box"
            session_lease={@session_lease}
            account={signed_in_account(@access_context)}
          />
        </:pairing>
      </Regent.Account.agents_layout>
    </article>
    """
  end

  defp signed_in_account(%{principal: {:human, account}}), do: account

  defp read_agents(socket) do
    case socket.assigns.access_context.principal do
      {:human, account} ->
        Read.start(socket, :agents_read, account.privy_user_id, fn ->
          RegentAgents.list_my_agents(actor: %Person{privy_user_id: account.privy_user_id})
        end)

      _signed_out ->
        Read.clear(socket, :agents_read)
    end
  end

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
        kind: to_string(&1.harness),
        harness: Harness.label(&1.harness),
        wallet: &1.wallet,
        backed: not is_nil(&1.human_id),
        last_contact_iso: DateTime.to_iso8601(&1.last_contact_at),
        last_contact: RegentFormat.relative_time(&1.last_contact_at, now),
        light: nil,
        light_label: nil
      }
    )
  end
end
