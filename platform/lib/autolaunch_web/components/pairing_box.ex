defmodule AutolaunchWeb.PairingBox do
  @moduledoc """
  Pairing an agent (`RegentAgents`): choosing it, the message to paste it with
  its code, "Make a new code", and the agent's name once it uses the code, in the
  shared pairing box (`Regent.Account.pairing`), as the template's is. Each agent
  keeps its own code until it expires, so choosing another agent and coming back
  shows the same message. The Account page holds the one box (`#account-pairing`),
  where the account menu's Pair New Agent leads.

  The parent passes `account` (the signed-in account), its `session_lease` and
  `id`; `AutolaunchWeb.Live.Agents` sends `agents_changed: true` when an agent
  pairs, checks in or is unpaired anywhere.
  """
  use AutolaunchWeb, :live_component

  alias AutolaunchWeb.Live.Session
  alias RegentAgents.{Harness, PairingCode, PairingMessage, Person}

  require Logger

  # Stands in for a code before one is made, so the message keeps its size.
  @no_code String.duplicate("X", 24)

  @impl true
  def mount(socket),
    do:
      {:ok,
       socket
       |> Session.check_component_lease(&take_account/2)
       |> assign(chosen: nil, codes: %{})}

  @impl true
  def update(%{agents_changed: true}, socket), do: {:ok, after_pairing(socket)}

  def update(%{account: account, id: id, session_lease: lease}, socket),
    do: {:ok, socket |> assign(id: id, session_lease: lease) |> take_account(account)}

  # The account as the page gave it, or as it reads now before each event
  # (`Session.check_component_lease/2`).
  defp take_account(socket, account),
    do: assign(socket, person: %Person{privy_user_id: account.privy_user_id})

  # Choosing an agent shows its code, made the first time it is chosen and again
  # once it has expired; asking for a new code replaces the chosen agent's. Codes
  # made before keep working until they expire.
  @impl true
  def handle_event("choose_agent", %{"harness" => harness}, socket),
    do: {:noreply, with_offered(socket, harness, &show/2)}

  def handle_event("new_pairing_code", %{"harness" => harness}, socket),
    do: {:noreply, with_offered(socket, harness, &issue/2)}

  # Nothing chosen: a reconnecting page restores the form with no agent picked,
  # and a submit can come before a choice. The box stays as it is.
  def handle_event(event, _nothing_chosen, socket)
      when event in ["choose_agent", "new_pairing_code"],
      do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <Regent.Account.pairing
        id={@id}
        harnesses={harnesses()}
        phx-change="choose_agent"
        phx-submit="new_pairing_code"
        phx-target={@myself}
        {pairing(@chosen, @codes[@chosen])}
      />
    </div>
    """
  end

  # The agents the pair request accepts on this site (`RegentAgents.Harness.offered/0`).
  defp harnesses,
    do:
      for(
        harness <- Harness.offered(),
        do: %{value: to_string(harness), label: Harness.label(harness)}
      )

  # The pairing box's state. Every agent's message is drawn, the chosen one shown,
  # so the box keeps one size; before a code is made a stand-in holds its place.
  defp pairing(nil, nil), do: %{messages: messages(@no_code)}

  defp pairing(harness, %PairingCode.Issued{} = code) do
    %{
      chosen: to_string(harness),
      messages: messages(code.code),
      message: agent_message(code.code, harness),
      expires_iso: DateTime.to_iso8601(code.expires_at),
      expires: Calendar.strftime(code.expires_at, "%H:%M UTC")
    }
  end

  defp pairing(harness, {:paired, agent}),
    do: %{
      chosen: to_string(harness),
      messages: messages(@no_code),
      outcome: {:paired, agent.name}
    }

  defp pairing(harness, :unavailable),
    do: %{chosen: to_string(harness), messages: messages(@no_code), outcome: :unavailable}

  defp messages(code),
    do: Harness.offered() |> Enum.map(&agent_message(code, &1)) |> Enum.uniq()

  defp with_offered(socket, harness, then) do
    with {:ok, harness} <- Harness.match(harness),
         true <- harness in Harness.offered() do
      then.(socket, harness)
    else
      _not_offered -> socket
    end
  end

  defp show(socket, harness) do
    socket = assign(socket, chosen: harness)
    if usable?(socket.assigns.codes[harness]), do: socket, else: issue(socket, harness)
  end

  # A code still in time, or the agent that used it; a missing, expired or failed
  # code is made again.
  defp usable?(%PairingCode.Issued{expires_at: expires_at}),
    do: DateTime.after?(expires_at, DateTime.utc_now())

  defp usable?({:paired, _agent}), do: true
  defp usable?(_missing_or_unavailable), do: false

  # The code on screen gives way to the agent that used it, so a spent code is
  # never left there to send again.
  defp after_pairing(%{assigns: %{chosen: chosen, codes: codes}} = socket) do
    with %PairingCode.Issued{issued_at: issued_at} <- codes[chosen],
         {:ok, agents} <- RegentAgents.list_my_agents(actor: socket.assigns.person),
         %{} = agent <- Enum.find(agents, &(DateTime.compare(&1.paired_at, issued_at) != :lt)) do
      assign(socket, codes: Map.put(codes, chosen, {:paired, agent}))
    else
      _unchanged -> socket
    end
  end

  # A code is made only under the page's lease read again now, so a page that
  # keeps showing its account while the sign-in could not be read makes none.
  defp issue(socket, harness) do
    code =
      case Session.transact(socket, fn ->
             RegentAgents.issue_pairing_code(actor: socket.assigns.person)
           end) do
        {:ok, issued} ->
          issued

        {:error, error} ->
          Logger.warning("A pairing code couldn't be made: #{inspect(failure_kinds(error))}")
          :unavailable
      end

    assign(socket, chosen: harness, codes: Map.put(socket.assigns.codes, harness, code))
  end

  # The kinds of failure alone: the failure's words can hold the person's id.
  defp failure_kinds(%{errors: [_ | _] = errors}), do: Enum.map(errors, & &1.__struct__)
  defp failure_kinds(error) when is_atom(error), do: [error]
  defp failure_kinds(error), do: [error.__struct__]

  # What the person pastes to their agent.
  defp agent_message(code, harness),
    do: PairingMessage.text(code, AutolaunchWeb.Endpoint.url(), harness)
end
