defmodule AutolaunchWeb.Components.SidePanel do
  @moduledoc """
  The side panel, the template's: its button sits beside the account name in the
  top bar, and either one opens it. Its top holds the signed-in name with
  Account and Sign out, then the box to pair an agent (the `pairing` slot, the
  Account page's own `AutolaunchWeb.PairingBox`) and a link to manage agents on
  the Regents account page, where the person signs in again. On a wide screen
  it slides in beside the page, which narrows to make room; on a narrower one it
  slides in over the page's edge. The browser alone opens and closes it
  (`assets/js/shell_panels.ts`, on `<html data-aside>`), so the server never
  stores it.

  The panel and its button are there only for someone signed in, as the
  template's are, so a page signed out has nothing beside the Sign in button.
  """
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl, only: [account_name: 1]

  alias Phoenix.LiveView.JS

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true

  @doc "The top bar's button for the side panel."
  def button(assigns) do
    ~H"""
    <button
      :if={@account_control.kind == :signed_in}
      id="shell-aside-button"
      class="shell-tool"
      type="button"
      aria-controls="shell-aside"
      aria-expanded="false"
      aria-label="Side panel"
      data-aside-toggle
      phx-mounted={JS.ignore_attributes(["aria-expanded"])}
    >
      <svg
        class="shell-icon"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="square"
        aria-hidden="true"
      ><path d="M3 4h18v16H3zM15 4v16" /></svg>
    </button>
    """
  end

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true
  slot :pairing, doc: "The box to pair an agent, on a LiveView page."

  def panel(assigns) do
    ~H"""
    <aside
      :if={@account_control.kind == :signed_in}
      id="shell-aside"
      aria-labelledby="shell-aside-title"
      tabindex="-1"
    >
      <div class="shell-aside__head">
        <h2 id="shell-aside-title">For you</h2>
        <button
          class="shell-tool"
          type="button"
          aria-controls="shell-aside"
          aria-label="Close the side panel"
          data-aside-close
        >
          <svg
            class="shell-icon"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="square"
            aria-hidden="true"
          ><path d="M6 6l12 12M18 6 6 18" /></svg>
        </button>
      </div>

      <section id="shell-account" class="shell-account" aria-label="Your account">
        <p class="shell-account__name"><.account_name account_control={@account_control} /></p>
        <div class="shell-account__actions">
          <.link navigate="/account" class="rg-button rg-button--secondary">Account</.link>
          <Regent.Primitives.button variant="secondary" type="button" data-account-target="sign-out">
            Sign out
          </Regent.Primitives.button>
        </div>
      </section>

      <section id="shell-pairing" aria-labelledby="shell-pairing-title">
        <h3 id="shell-pairing-title">Pair your agent</h3>
        {render_slot(@pairing)}
        <a href="https://regents.sh/account#account-agents">Manage Agents</a>
      </section>
    </aside>
    """
  end
end
