defmodule AutolaunchWeb.TestFundsComponent do
  @moduledoc """
  Lab-only test funds for the wallet the customer signed in with.

  Every press sends one fork transaction from the site; nothing here opens the
  customer's wallet. Buttons never wait on an earlier press, and a failure is
  reported as the lab's own error text.
  """

  use AutolaunchWeb, :live_component

  alias Autolaunch.Stocks.Faucet
  alias AutolaunchWeb.Live.Session
  alias AutolaunchWeb.OnchainSteps

  def available?, do: Faucet.available?()

  # Each press and each answer first checks the sign-in, and the wallet the
  # funds go to is the account's as it reads now.
  @impl true
  def mount(socket),
    do: {:ok, Session.check_component_lease(socket, &OnchainSteps.take(&1, &2, fn s -> s end))}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     socket
     |> OnchainSteps.adopt()
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
      <p :if={@signed_in} class="autolaunch-draft-hint">
        Receiving wallet: <span class="launch-wallet-mono">{@signed_in}</span>
      </p>
      <div :if={@signed_in} class="launch-wallet-controls">
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
  # One press, one transaction, started right away under its own name; the
  # result lands when the lab answers, and a second press meanwhile is another
  # transaction.
  def handle_event("grant", %{"kind" => kind} = params, socket) do
    wallet = socket.assigns.signed_in

    {:noreply,
     socket
     |> assign(outcome: nil)
     |> start_async({:grant, make_ref()}, fn -> grant(kind, wallet, params["stock"]) end)}
  end

  @impl true
  def handle_async({:grant, _press}, {:ok, result}, socket),
    do: {:noreply, assign(socket, outcome: result)}

  def handle_async({:grant, _press}, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket, outcome: {:error, "That did not go through. Try again in a moment."})}

  defp grant(_kind, nil, _stock), do: {:error, "Sign in to receive test funds."}
  defp grant("regent", wallet, _stock), do: Faucet.regent(wallet)
  defp grant("stock", wallet, stock) when is_binary(stock), do: Faucet.stock(wallet, stock)
  defp grant("usdc", wallet, _stock), do: Faucet.usdc(wallet)
  defp grant(_kind, _wallet, _stock), do: {:error, "That test asset is not available."}

  defp grant_copy({:ok, %{symbol: symbol, amount: amount, balance: balance, hash: hash}}),
    do:
      "Sent #{amount} #{symbol}. This wallet now holds #{balance} #{symbol}. Transaction #{hash}."
end
