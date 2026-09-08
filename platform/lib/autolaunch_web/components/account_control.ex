defmodule AutolaunchWeb.Components.AccountControl do
  @moduledoc false
  use Phoenix.Component

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true

  def account_control(assigns) do
    ~H"""
    <div
      id="account-control"
      class="account-control"
      data-account-kind={@account_control.kind}
    >
      <Regent.Primitives.button
        :if={@account_control.kind == :sign_in}
        type="button"
        class="account-control__sign-in"
        data-account-target="sign-in"
        disabled={Autolaunch.Prelaunch.read_only?()}
        title={if Autolaunch.Prelaunch.read_only?(), do: "Accounts are unavailable during prelaunch"}
      >
        Sign in
      </Regent.Primitives.button>

      <div :if={@account_control.kind == :signed_in} class="account-control__signed-in">
        <span class="account-control__label">{@account_control.label}</span>
        <.link href="/portfolio" class="account-control__portfolio">Portfolio</.link>
        <.link href="/profile" class="account-control__portfolio">Profile</.link>
        <Regent.Primitives.button
          type="button"
          class="account-control__sign-out"
          data-account-target="sign-out"
          disabled={Autolaunch.Prelaunch.read_only?()}
          variant="secondary"
        >
          Sign out
        </Regent.Primitives.button>
      </div>

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
end
