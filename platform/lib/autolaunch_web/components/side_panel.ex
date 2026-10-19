defmodule AutolaunchWeb.Components.SidePanel do
  @moduledoc """
  The side panel, the template's: its button sits beside the account name in the
  top bar, and either one opens it; the same button closes it. Its first row
  holds Account and Sign out. Then come the person's agents with where each was
  last active (the `agents` slot, `AutolaunchWeb.PanelAgents`), then the box to
  pair a new one (the `pairing` slot, the Account page's own
  `AutolaunchWeb.PairingBox`). A page that shows its own pairing box leaves that
  slot out, and a page served without LiveView, which cannot hold either, leaves
  both out. On a wide screen it slides in beside the page, which narrows to make
  room; on a narrower one it slides in over the page's edge, and on a phone it
  takes the whole screen under the top bar. A phone's top bar has no room for
  the Credits balance, so there the panel shows it. The browser alone opens and
  closes it (`assets/js/shell_panels.ts`, on `<html data-aside>`), so the server
  never stores it.

  The panel and its button are there only for someone signed in, as the
  template's are, so a page signed out has nothing beside the Sign in button.
  """
  use Phoenix.Component

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

  attr :credits, :map,
    required: true,
    doc: "As for `AutolaunchWeb.Components.Credits.button/1`; shown here only on a phone."

  slot :agents,
    doc: "The agents paired with the account, on a LiveView page; left out on any other."

  slot :pairing,
    doc: "The box to pair an agent, on a LiveView page; left out on a page with its own."

  def panel(assigns) do
    ~H"""
    <aside
      :if={@account_control.kind == :signed_in}
      id="shell-aside"
      aria-label="Your account and agents"
      tabindex="-1"
    >
      <div id="shell-account" class="shell-aside__head">
        <AutolaunchWeb.Components.Credits.button id="shell-aside-credits-button" credits={@credits} />
        <.link navigate="/account" class="rg-button rg-button--secondary">Account</.link>
        <Regent.Primitives.button variant="secondary" type="button" data-account-target="sign-out">
          Sign out
        </Regent.Primitives.button>
      </div>

      {render_slot(@agents)}

      <section :if={@pairing != []} id="shell-pairing" aria-labelledby="shell-pairing-title">
        <h2 id="shell-pairing-title">Pair New Agent</h2>
        {render_slot(@pairing)}
      </section>
    </aside>
    """
  end
end
