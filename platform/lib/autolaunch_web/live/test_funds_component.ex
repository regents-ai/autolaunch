defmodule AutolaunchWeb.TestFundsComponent do
  @moduledoc """
  Lab-only test funds for the wallet the customer signed in with.

  Every press sends one fork transaction from the site; nothing here opens the
  customer's wallet. Buttons never wait on an earlier press, and a failure is
  reported as the lab's own error text.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Stocks.Faucet
  alias AutolaunchWeb.SignedInWallet

  def available?, do: Faucet.available?()

  @impl true
  def update(%{grant: result}, socket), do: {:ok, assign(socket, outcome: result)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> SignedInWallet.adopt(&assign(&1, wallet: &2))
     |> assign_new(:outcome, fn -> nil end)
     |> assign(:stocks, Faucet.stocks())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="launchpad-form-section rg-panel rg-panel--surface"
      aria-label="Test funds"
    >
      <header>
        <div>
          <p class="autolaunch-kicker">{Autolaunch.ChainMode.label()}</p>
          <Regent.Structure.section_bar>
            <h2 class="rg-section-bar__label">Test funds</h2>
          </Regent.Structure.section_bar>
        </div>
      </header>
      <p>
        Test assets on this Base fork only; they have no mainnet value. Funds go to the
        receiving wallet shown below.
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

  defp grant(_kind, nil, _stock), do: {:error, "Sign in to receive test funds."}
  defp grant("regent", wallet, _stock), do: Faucet.regent(wallet)
  defp grant("stock", wallet, stock) when is_binary(stock), do: Faucet.stock(wallet, stock)
  defp grant("usdc", wallet, _stock), do: Faucet.usdc(wallet)
  defp grant(_kind, _wallet, _stock), do: {:error, "That test asset is not available."}

  defp grant_copy({:ok, %{symbol: symbol, amount: amount, balance: balance, hash: hash}}),
    do:
      "Sent #{amount} #{symbol}. This wallet now holds #{balance} #{symbol}. Transaction #{hash}."
end
