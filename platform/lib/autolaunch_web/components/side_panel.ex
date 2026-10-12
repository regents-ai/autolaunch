defmodule AutolaunchWeb.Components.SidePanel do
  @moduledoc """
  The side panel, the template's: its button sits beside the account name in the
  top bar, and either one opens it. Its top holds the signed-in name with
  Account and Sign out, then Help. The browser alone opens and closes it
  (`assets/js/shell_panels.ts`, on `<html data-aside>`), so the server never
  stores it.
  """
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl, only: [account_name: 1]

  alias Phoenix.LiveView.JS

  @help [
    {"Documentation", "/docs"},
    {"How it works", "/how-it-works"},
    {"Agent guide", "/llms.txt"},
    {"Contact", "/contact"}
  ]

  @doc "The top bar's button for the side panel."
  def button(assigns) do
    ~H"""
    <button
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

  def panel(assigns) do
    assigns = assign(assigns, :help, @help)

    ~H"""
    <aside id="shell-aside" aria-labelledby="shell-aside-title" tabindex="-1">
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

      <section
        :if={@account_control.kind == :signed_in}
        id="shell-account"
        class="shell-account"
        aria-label="Your account"
      >
        <p class="shell-account__name"><.account_name account_control={@account_control} /></p>
        <div class="shell-account__actions">
          <.link navigate="/account" class="rg-button rg-button--secondary">Account</.link>
          <Regent.Primitives.button variant="secondary" type="button" data-account-target="sign-out">
            Sign out
          </Regent.Primitives.button>
        </div>
      </section>

      <section id="shell-aside-help" aria-labelledby="shell-help-title">
        <h3 id="shell-help-title">Help</h3>
        <ul>
          <li :for={{label, path} <- @help}><a href={path}>{label}</a></li>
        </ul>
      </section>
    </aside>
    """
  end
end
