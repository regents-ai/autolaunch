defmodule AutolaunchWeb.Components.AccountControl do
  @moduledoc """
  The account control in the top bar, the template's: Sign in, or the signed-in
  picture and name, which open the account menu (`Regent.Account.menu`, drawn
  from the top bar) under the button. The browser opens and closes the menu
  (`popover`). auth_lazy.ts drives the `data-account-target` markers; the
  component itself never authenticates anyone.
  """
  use Phoenix.Component

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true

  def account_control(assigns) do
    ~H"""
    <div id="account-control" class="account-control">
      <Regent.Primitives.button
        :if={@account_control.kind == :sign_in}
        type="button"
        class="account-control__sign-in"
        data-account-target="sign-in"
      >
        Sign in
      </Regent.Primitives.button>
      <button
        :if={@account_control.kind == :signed_in}
        id="account-chip"
        class="account-chip"
        type="button"
        popovertarget="account-menu"
      >
        <.account_name account_control={@account_control} />
      </button>
      <p
        id="account-auth-status"
        class="account-control__status"
        role="status"
        aria-live="polite"
        aria-atomic="true"
        phx-update="ignore"
        hidden
      >
      </p>
    </div>
    """
  end

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true

  @doc """
  The account's picture and name. The `profile` marker tells the browser the
  page was drawn for a signed-in account.
  """
  def account_name(assigns) do
    ~H"""
    <img
      :if={@account_control.avatar_src}
      class="account-avatar"
      src={@account_control.avatar_src}
      referrerpolicy="no-referrer"
      width="36"
      height="36"
      alt=""
    />
    <span class="account-name" data-account-target="profile">{@account_control.label}</span>
    """
  end
end
