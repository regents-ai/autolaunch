defmodule AutolaunchWeb.TestFundsComponent do
  @moduledoc """
  Lab-only test funds for the signed-in account's active wallet.

  Every press sends one fork transaction from the site; nothing here opens the
  customer's wallet. Buttons never wait on an earlier press, and a failure is
  reported as the lab's own error text.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Chain.Address
  alias Autolaunch.Stocks.Faucet

  def available?, do: Faucet.available?()

  @impl true
  def update(%{grant: result}, socket), do: {:ok, assign(socket, outcome: result)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> assign_new(:wallet, fn -> primary_wallet(socket) end)
     |> assign_new(:outcome, fn -> nil end)
     |> assign(:stocks, Faucet.stocks())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="launchpad-form-section rg-panel rg-panel--surface"
      phx-hook="AutolaunchTestFunds"
      phx-target={@myself}
      aria-label="Test funds"
    >
      <header>
        <div>
          <p class="autolaunch-kicker">Local lab</p>
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label">Test funds</h2>
          </Regent.Structure.section_bar>
        </div>
      </header>
      <p>
        Test assets on the local fork only; they have no mainnet value. Funds go to the
        receiving wallet shown below.
      </p>
      <p :if={!@wallet} class="autolaunch-draft-hint">
        Sign in with a wallet on this account to receive test funds.
      </p>
      <p :if={@wallet} class="autolaunch-draft-hint">
        Receiving wallet: <span class="launch-wallet-mono">{@wallet}</span>
      </p>
      <div :if={@wallet} class="launch-wallet-controls">
        <Regent.Primitives.button
          type="button"
          phx-click="grant"
          phx-value-kind="regent"
          phx-target={@myself}
          variant="secondary"
        >
          Get 1,000 test REGENT
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :for={stock <- @stocks}
          type="button"
          phx-click="grant"
          phx-value-kind="stock"
          phx-value-stock={stock.address}
          phx-target={@myself}
          variant="secondary"
        >
          Get test {stock.symbol}
        </Regent.Primitives.button>
        <Regent.Primitives.button
          :if={@stocks != []}
          type="button"
          phx-click="grant"
          phx-value-kind="usdc"
          phx-target={@myself}
          variant="secondary"
        >
          Get 1,000 test USDC
        </Regent.Primitives.button>
      </div>
      <p
        :if={match?({:ok, _}, @outcome)}
        class="autolaunch-draft-notice autolaunch-draft-notice--success"
        role="status"
      >
        {grant_copy(@outcome)}
      </p>
      <p :if={match?({:error, _}, @outcome)} class="autolaunch-draft-error" role="alert">
        {elem(@outcome, 1)}
      </p>
    </section>
    """
  end

  @impl true
  # The browser names its active wallet; when it has none yet, the account's
  # verified primary wallet stays the recipient.
  def handle_event("test_funds_wallet", %{"address" => address}, socket) when is_binary(address),
    do: {:noreply, assign(socket, wallet: held_wallet(socket, address) || primary_wallet(socket))}

  def handle_event("test_funds_wallet", _params, socket),
    do: {:noreply, assign(socket, wallet: primary_wallet(socket))}

  # One press, one transaction, started right away; the result lands when the
  # lab answers, and a second press meanwhile is another transaction.
  def handle_event("grant", %{"kind" => kind} = params, socket) do
    wallet = socket.assigns.wallet
    pid = self()
    id = socket.assigns.id

    Task.start(fn ->
      send_update(pid, __MODULE__, id: id, grant: grant(kind, wallet, params["stock"]))
    end)

    {:noreply, assign(socket, outcome: nil)}
  end

  defp grant(_kind, nil, _stock), do: {:error, "Choose a wallet on this account first."}
  defp grant("regent", wallet, _stock), do: Faucet.regent(wallet)
  defp grant("stock", wallet, stock) when is_binary(stock), do: Faucet.stock(wallet, stock)
  defp grant("usdc", wallet, _stock), do: Faucet.usdc(wallet)
  defp grant(_kind, _wallet, _stock), do: {:error, "That test asset is not available."}

  # Only a wallet the signed-in account really holds receives anything.
  defp held_wallet(socket, address) do
    with {:ok, %{wallet_addresses: wallets}} <- leased_account(socket),
         {:ok, wallet} <- Address.normalize(address),
         true <- Enum.any?(wallets || [], &Address.equal?(&1, wallet)) do
      wallet
    else
      _unheld -> nil
    end
  end

  # Until the browser names an active wallet, the account's verified primary
  # wallet receives test funds; the bridge's later choice replaces it.
  defp primary_wallet(socket) do
    with {:ok, %{wallet_address: address}} when is_binary(address) <- leased_account(socket),
         {:ok, wallet} <- Address.normalize(address) do
      wallet
    else
      _absent -> nil
    end
  end

  defp leased_account(socket) do
    with %{lineage: lineage, account_id: id} <- socket.assigns[:session_lease],
         true <- socket.assigns[:current_human_id] == id,
         %{} = account <- SessionAuthority.leased_account(lineage, id) do
      {:ok, account}
    else
      _unleased -> :error
    end
  end

  defp grant_copy({:ok, %{symbol: symbol, amount: amount, balance: balance, hash: hash}}),
    do:
      "Sent #{amount} #{symbol}. This wallet now holds #{balance} #{symbol}. Transaction #{hash}."
end
