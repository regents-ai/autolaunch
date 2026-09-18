defmodule AutolaunchWeb.Components.SwapModal do
  @moduledoc false
  use Phoenix.Component

  attr :id, :string, required: true
  attr :token, :map, required: true
  attr :authenticated, :boolean, default: false
  attr :current_human_id, :integer, default: nil
  attr :session_lease, :map, default: nil
  attr :continue_path, :string, default: nil

  def swap_modal(assigns) do
    assigns = assign(assigns, :presentation, Autolaunch.Token.presentation(assigns.token))

    ~H"""
    <dialog
      id={@id}
      class="token-swap-modal"
      phx-hook="AutolaunchSwapDialog"
      data-token-id={@token.id}
      aria-labelledby={@id <> "-title"}
      aria-modal="true"
    >
      <header class="token-swap-modal__header">
        <h2 id={@id <> "-title"}>Trade {@presentation.symbol}</h2>
        <Regent.Primitives.button variant="quiet" data-close-swap aria-label="Close swap form">
          Close
        </Regent.Primitives.button>
      </header>
      <.live_component
        module={AutolaunchWeb.SwapComponent}
        id={@id <> "-input"}
        token={@token}
        authenticated={@authenticated}
        current_human_id={@current_human_id}
        session_lease={@session_lease}
        continue_path={@continue_path}
      />
    </dialog>
    """
  end
end
