defmodule AutolaunchWeb.OnchainSteps do
  @moduledoc """
  The server half of every wallet panel, as the template's `OnchainSteps`
  (`skills/onchain-buttons` has the rules).

  A panel builds a `RegentChain.Review` for the eligible signer and hands it to
  `put_review/2`, which remembers it and pushes it to the page before anyone
  presses. The page reports each press against the review it sent from. Every
  sent step is then read at the latest block of the review's chain, every two
  seconds, until it lands or the page stops asking. Nothing is kept beyond the
  page.

  The only wallet that may act is Privy's active wallet when it is one of the
  signed-in account's own (`signer/2`). Reads that show another wallet never
  imply that wallet can send.
  """

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [push_event: 3, send_update_after: 4, start_async: 3]

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Chain.Client
  alias RegentChain.{Address, Outcome, Presses}

  @recheck_ms 2_000

  # A review's deadlines and allowance windows are fifteen minutes long, so one
  # is built again once it is ten minutes old.
  @stale_ms 10 * 60_000

  @doc "The assigns a wallet panel starts with."
  def init(socket),
    do: assign(socket, presses: Presses.new(), review: nil, press_note: nil, active: nil)

  @doc """
  Reads the signed-in account's wallets once for each session lease the panel
  is given: `linked`, all of them lowercase (`nil` signed out), and
  `signed_in`, the one it signed in with, whose figures a panel shows until
  Privy reports its active wallet.
  """
  def adopt(%{assigns: assigns} = socket) do
    lease = {assigns[:session_lease], assigns[:current_human_id]}

    if Map.get(assigns, :linked_for) == lease do
      socket
    else
      {linked, signed_in} = account_wallets(assigns)
      assign(socket, linked_for: lease, linked: linked, signed_in: signed_in)
    end
  end

  defp account_wallets(assigns) do
    with %{lineage: lineage, account_id: id} <- assigns[:session_lease],
         true <- assigns[:current_human_id] == id,
         %{wallet_addresses: wallets, wallet_address: primary} <-
           SessionAuthority.leased_account(lineage, id) do
      linked = wallets |> Enum.flat_map(&normalized/1) |> Enum.uniq()
      {linked, primary |> normalized() |> List.first()}
    else
      _signed_out -> {nil, nil}
    end
  end

  defp normalized(wallet) do
    case Address.normalize(wallet) do
      {:ok, address} -> [address]
      :error -> []
    end
  end

  @doc """
  The wallet that may act: Privy's `active` wallet when the signed-in account
  links it, lowercased. Signed out (`linked` is `nil`), with no active wallet, or
  with one the account does not link, nothing may act.
  """
  def signer(nil, _active), do: nil
  def signer(_linked, nil), do: nil

  def signer(linked, active) do
    active = String.downcase(active)
    if active in Enum.map(linked, &String.downcase/1), do: active
  end

  @doc "Privy's active wallet as the page reported it, or `nil`."
  def active_wallet(%{"address" => address}) do
    case Address.normalize(address) do
      {:ok, active} -> active
      :error -> nil
    end
  end

  def active_wallet(_params), do: nil

  @doc """
  Puts `review` (or none) on the page when it is not the one already there. A
  review is fixed once built, so a new signer, chain or figure is a new review,
  and the page drops the old one as soon as this arrives.
  """
  def put_review(socket, review) do
    if review_id(review) == review_id(socket.assigns.review) do
      socket
    else
      presses =
        if review,
          do: Presses.remember(socket.assigns.presses, review),
          else: socket.assigns.presses

      socket
      |> assign(review: review, presses: presses)
      |> push_event("onchain-steps:review", %{component_id: socket.assigns.id, review: review})
    end
  end

  @doc "Opens Privy's connect step on the page, for a review that needs a wallet when none is active."
  def connect(socket),
    do: push_event(socket, "onchain-steps:connect", %{component_id: socket.assigns.id})

  @doc "The wallet sent a step; it is read from now on against the review it was sent from."
  def sent(socket, params) do
    case Presses.sent(socket.assigns.presses, params) do
      {:ok, entry, presses} ->
        socket |> assign(presses: presses, press_note: nil) |> check(entry)

      :error ->
        socket
    end
  end

  @doc """
  The newest press of step `name` of `review`, or `nil` when that step has not
  been sent from it. A panel reads a step's state from it and never waits on it.
  """
  def entry(presses, %{id: id}, name) do
    Enum.find(Presses.shown(presses), &(&1.name == name and match?(%{id: ^id}, &1.review)))
  end

  @doc "Whether a step sent from `review` is still on its way."
  def pending?(presses, %{steps: steps} = review),
    do: Enum.any?(steps, &match?(%{outcome: :pending}, entry(presses, review, &1.step)))

  @doc """
  Asks the panel to look at the review on the page again once it is ten
  minutes old, as `update(%{refresh_review: review_id}, socket)`. The panel
  builds a fresh one when that review is still there and nothing sent from it
  is on its way, and asks again otherwise; the new review reaches the page at
  once, so a press always sends what is on the page.
  """
  def refresh_later(%{assigns: %{review: %{id: review_id}, myself: myself}} = socket) do
    send_update_after(self(), myself, %{refresh_review: review_id}, @stale_ms)
    socket
  end

  def refresh_later(socket), do: socket

  @doc "Starts reading a step again after the page stopped on its own."
  def check_again(socket, hash) do
    case Presses.check_again(socket.assigns.presses, hash) do
      {nil, _presses} -> socket
      {entry, presses} -> socket |> assign(presses: presses) |> check(entry)
    end
  end

  @doc """
  One answer from `handle_async({:onchain_step, hash}, result, socket)`.
  `confirmed` runs once, with the entry, when the step lands and succeeds, so
  the panel can read its figures again; `reverted` runs once when it lands and
  reverts, so the panel can build its review again.
  """
  def checked(
        socket,
        hash,
        result,
        confirmed \\ fn socket, _entry -> socket end,
        reverted \\ fn socket, _entry -> socket end
      ) do
    answer =
      case result do
        {:ok, answer} -> answer
        {:exit, _reason} -> :unanswered
      end

    case Presses.checked(socket.assigns.presses, hash, answer) do
      {nil, _presses} ->
        socket

      {entry, presses} ->
        socket = assign(socket, presses: presses)

        cond do
          Presses.reading?(entry) -> check(socket, entry)
          entry.outcome == :confirmed -> confirmed.(socket, entry)
          entry.outcome == :reverted -> reverted.(socket, entry)
          true -> socket
        end
    end
  end

  @doc """
  What to say when a press sent nothing, or may have sent something, in words
  for the person who pressed. `linked` and `active` are the account's wallets
  (`nil` signed out) and Privy's active wallet, as for `signer/2`.
  """
  def failure_note(reason, linked, active, chain_name)

  def failure_note(reason, nil, _active, _chain_name)
      when reason in ~w(step_unknown wallet_unavailable),
      do: "Sign in to send this. Nothing was sent."

  def failure_note(reason, _linked, nil, _chain_name)
      when reason in ~w(step_unknown wallet_unavailable),
      do: "Connect your wallet, then press again. Nothing was sent."

  def failure_note(reason, linked, active, _chain_name)
      when reason in ~w(step_unknown wallet_unavailable) do
    cond do
      signer(linked, active) == nil ->
        "Switch to a wallet on your account in your wallet app, then press again. Nothing was sent."

      reason == "step_unknown" ->
        "This can't be sent as it stands. Check the details above, then press again. Nothing was sent."

      true ->
        "Your wallet changed during the press, so nothing was sent. Press again."
    end
  end

  def failure_note("network_mismatch", _linked, _active, chain_name),
    do:
      "Your wallet is on a different network. Switch it to #{chain_name}, then press again. Nothing was sent."

  def failure_note("wallet_declined", _linked, _active, _chain_name),
    do: "Your wallet declined this. Nothing was sent."

  def failure_note("insufficient_funds", _linked, _active, chain_name),
    do:
      "Your wallet doesn't have enough on #{chain_name} to pay the network fee. Nothing was sent."

  def failure_note("send_unconfirmed", _linked, _active, _chain_name),
    do: "Your wallet may have sent this. Check your wallet activity."

  @doc """
  The note beside the buttons while the wallet app has open a wallet the
  signed-in account does not link, naming both.
  """
  def mismatch_note(linked, active) when is_list(linked) and is_binary(active) do
    if signer(linked, active) == nil do
      "You're signed in with #{Enum.map_join(linked, " and ", &short/1)}, but your wallet app has #{short(active)} open."
    end
  end

  def mismatch_note(_linked, _active), do: nil

  @doc """
  One sent step as the page shows it: its state and generic words. A panel
  names its steps and may say more about them.
  """
  def describe(entry, chain_name) do
    state = if Presses.stalled?(entry), do: :stalled, else: entry.outcome
    %{hash: entry.hash, state: state, words: words(state, chain_name)}
  end

  defp words(:pending, chain_name), do: "Sent. Waiting for #{chain_name}."

  defp words(:stalled, chain_name),
    do: "#{chain_name} has not confirmed this yet. Check again, or look in your wallet activity."

  defp words(:confirmed, _chain_name), do: "Done."
  defp words(:reverted, _chain_name), do: "This did not go through and nothing moved."

  defp words(_not_this_step, _chain_name),
    do:
      "This transaction is not the one this page prepared, so it can't be followed here. Check it in your wallet activity."

  defp check(socket, %{step: nil}), do: socket

  defp check(socket, %{hash: hash, reads: reads, review: review, step: step}) do
    start_async(socket, {:onchain_step, hash}, fn ->
      if reads > 0, do: Process.sleep(@recheck_ms)
      Outcome.of(Client, review, step, hash)
    end)
  end

  defp review_id(nil), do: nil
  defp review_id(%{id: id}), do: id

  defp short(address), do: RegentFormat.short_address(address)
end
