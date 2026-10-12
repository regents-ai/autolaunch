defmodule AutolaunchWeb.Components.Credits do
  @moduledoc """
  The header's Credits button and the Buy Credits window it opens, the
  template's. Both show only to a signed-in person on a LiveView page
  (`AutolaunchWeb.Layouts.credits/3`). The browser alone opens and closes the
  window (`assets/js/shell_panels.ts`), so the server never stores it.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :credits, :map,
    required: true,
    doc: "The account and its Credits reading (`AutolaunchWeb.Layouts.credits/3`), or nil."

  def button(%{credits: nil} = assigns), do: ~H""

  def button(assigns) do
    ~H"""
    <button
      id="shell-credits-button"
      class="shell-credits"
      type="button"
      aria-haspopup="dialog"
      aria-controls="shell-credits"
      aria-label={label(@credits.read)}
      phx-hook="MotionCount"
      data-variant="flash"
    >
      <.amount read={@credits.read} />
    </button>
    """
  end

  attr :credits, :map, required: true, doc: "As for `button/1`."
  attr :session_lease, :map, required: true

  def dialog(%{credits: nil} = assigns), do: ~H""

  def dialog(assigns) do
    ~H"""
    <dialog
      id="shell-credits"
      class="shell-credits-dialog"
      aria-label="Buy Credits"
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <Regent.Primitives.button
        variant="quiet"
        type="button"
        class="shell-credits-dialog__close"
        aria-label="Close"
        data-credits-close
      >
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
      </Regent.Primitives.button>
      <.live_component
        module={AutolaunchWeb.CreditsPanel}
        id="credits-panel"
        account={@credits.account}
        credits={@credits.read}
        session_lease={@session_lease}
        current_human_id={@credits.account.id}
      />
    </dialog>
    """
  end

  defp label(%{state: :ready, value: balance}), do: RegentCredits.Amount.format(balance.available)
  defp label(%{state: state}) when state in [:error, :stale], do: "Credits unavailable"
  defp label(_read), do: "Credits loading"

  attr :read, AutolaunchWeb.Read, required: true

  # "12.40 Credits", whose unit a phone's header leaves out for room. Only a
  # balance just read shows; while it is read again, or when it can't be, the
  # figure is a dash. The button and the Buy Credits panel behind it are there
  # either way.
  defp amount(%{read: %{state: :ready, value: balance}} = assigns) do
    [number, unit] = String.split(RegentCredits.Amount.format(balance.available), " ", parts: 2)
    assigns = assign(assigns, number: number, unit: unit)

    ~H"""
    <span data-count>{@number}</span> <span class="shell-credits__unit">{@unit}</span>
    """
  end

  defp amount(assigns) do
    ~H"""
    <span data-count>—</span> <span class="shell-credits__unit">Credits</span>
    """
  end
end
