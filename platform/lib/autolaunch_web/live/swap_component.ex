defmodule AutolaunchWeb.SwapComponent do
  @moduledoc "Transient swap input shared by token detail and listing dialogs."
  use AutolaunchWeb, :live_component

  import AutolaunchWeb.Components.SwapForm

  def update(assigns, socket) do
    auction = assigns.token.auction

    scope =
      {assigns.token.id, auction.kind, auction.chain_id, auction.quote_token_address,
       auction.quote_token_symbol}

    socket =
      if socket.assigns[:scope] == scope do
        socket
      else
        assign(socket,
          scope: scope,
          direction: :buy,
          amount: "",
          error: nil,
          revision: Map.get(socket.assigns, :revision, -1) + 1
        )
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       token_view: Autolaunch.Token.presentation(assigns.token),
       entry_symbol: entry_symbol(auction)
     )}
  end

  def handle_event("amount-" <> revision, %{"amount" => amount}, socket)
      when is_binary(amount) and byte_size(amount) <= 256 do
    if revision == Integer.to_string(socket.assigns.revision) do
      error =
        if Regex.match?(~r/\A[0-9]*\.?[0-9]*\z/, amount),
          do: nil,
          else: "Enter an amount using digits and a decimal point."

      {:noreply, assign(socket, amount: amount, error: error)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("amount-" <> _revision, _params, socket), do: {:noreply, socket}

  def handle_event("reverse", _params, socket) do
    {:noreply,
     assign(socket,
       direction: if(socket.assigns.direction == :buy, do: :sell, else: :buy),
       amount: "",
       error: nil,
       revision: socket.assigns.revision + 1
     )}
  end

  # This presentation integration has no quote or transaction executor yet.
  # A forged submit cannot create an operation or request a wallet signature.
  def handle_event("swap", _params, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.swap_form
        :if={@entry_symbol}
        id={"#{@id}-form-#{@revision}"}
        sell_symbol={if @direction == :buy, do: @entry_symbol, else: @token_view.symbol}
        buy_symbol={if @direction == :buy, do: @token_view.symbol, else: @entry_symbol}
        sell_image={if @direction == :sell, do: @token_view.image}
        buy_image={if @direction == :buy, do: @token_view.image}
        amount={@amount}
        error={@error}
        action_label="Swap"
        action_enabled={false}
        disabled_reason="Trading is not available yet."
        change_event={"amount-#{@revision}"}
        submit_event="swap"
        reverse_event="reverse"
        target={@myself}
      />
      <p :if={!@entry_symbol} class="token-swap__notice" role="status">
        Trading is not available for this token yet.
      </p>
    </div>
    """
  end

  defp entry_symbol(%{kind: :agent, chain_id: chain_id, quote_token_symbol: "REGENT"}) do
    if base_chain?(chain_id), do: "REGENT"
  end

  defp entry_symbol(%{kind: :agent, chain_id: chain_id, quote_token_symbol: "USDG"}) do
    if chain_id == Autolaunch.Robinhood.Lab.chain_id(), do: "USDG"
  end

  defp entry_symbol(%{
         kind: :stocks,
         chain_id: chain_id,
         quote_token_address: address,
         quote_token_symbol: symbol
       })
       when is_binary(address) and address != "" and is_binary(symbol) do
    if base_chain?(chain_id) and String.trim(symbol) != "", do: symbol
  end

  defp entry_symbol(_auction), do: nil

  defp base_chain?(chain_id), do: chain_id in [8453, Autolaunch.Lab.chain_id()]
end
