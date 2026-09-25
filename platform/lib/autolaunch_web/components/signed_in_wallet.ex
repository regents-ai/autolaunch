defmodule AutolaunchWeb.SignedInWallet do
  @moduledoc """
  The wallet a panel acts for is the one the customer signed in with, read from
  the mounted session lease. The browser's wallet never picks it: the browser
  only reports which wallets it has connected, and a panel uses that report for
  one thing, the note beside its buttons when the signed-in wallet is not the
  one the browser is on. Buttons never wait on the browser's wallet; a press
  opens the wallet, or its connect step when the signed-in wallet is not
  connected in this tab.
  """

  use Phoenix.Component

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Chain.Address

  @reported 10

  @doc """
  Hands the signed-in wallet, or nil, to `adopt` once for each session lease the
  panel is given: when it first mounts and whenever it is given another. A panel
  whose read of that wallet failed sets `signed_in_for: nil`, so its next update
  reads again.
  """
  def adopt(%{assigns: assigns} = socket, adopt) do
    lease = {assigns[:session_lease], assigns[:current_human_id]}

    if Map.get(assigns, :signed_in_for) == lease,
      do: socket,
      else: socket |> assign(signed_in_for: lease) |> adopt.(address(assigns))
  end

  @doc "The signed-in wallet, lowercase, or nil when this panel has no live lease."
  def address(assigns) do
    with %{lineage: lineage, account_id: id} <- assigns[:session_lease],
         true <- assigns[:current_human_id] == id,
         %{wallet_address: wallet} <- SessionAuthority.leased_account(lineage, id),
         {:ok, wallet} <- Address.normalize(wallet) do
      wallet
    else
      _signed_out -> nil
    end
  end

  @doc "The browser's report of its connected wallets, the one it has selected first."
  def reported(%{"addresses" => addresses}) when is_list(addresses) do
    addresses
    |> Enum.take(@reported)
    |> Enum.flat_map(fn address ->
      case Address.normalize(address) do
        {:ok, wallet} -> [wallet]
        :error -> []
      end
    end)
  end

  def reported(_params), do: []

  attr :signed_in, :string, default: nil
  attr :browser, :list, default: []

  @doc "Names both wallets when the browser is on a wallet other than the signed-in one."
  def note(assigns) do
    assigns = assign(assigns, :other, other(assigns.signed_in, assigns.browser))

    ~H"""
    <p :if={@other} class="signed-in-wallet-note" role="status">
      You're signed in as {short(@signed_in)} but your wallet is on {short(@other)}.
      Switch your wallet to {short(@signed_in)}, then press again.
    </p>
    """
  end

  defp other(nil, _browser), do: nil

  defp other(signed_in, browser),
    do: if(signed_in in browser, do: nil, else: List.first(browser))

  @doc "An address as 0x45c9…98e0."
  def short("0x" <> _rest = address),
    do: "#{String.slice(address, 0, 6)}…#{String.slice(address, -4, 4)}"
end
