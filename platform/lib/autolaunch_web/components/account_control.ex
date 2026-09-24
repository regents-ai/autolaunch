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
      >
        Sign in
      </Regent.Primitives.button>

      <details :if={@account_control.kind == :signed_in} class="account-menu" data-account-menu>
        <summary
          class="account-menu__trigger"
          aria-label={"Account menu for #{@account_control.label}"}
        >
          <span class="account-menu__avatar">
            <img
              :if={@account_control.avatar_data_uri}
              src={@account_control.avatar_data_uri}
              alt=""
              width="36"
              height="36"
            />
            <img
              class="account-menu__wallet"
              data-account-wallet-badge
              alt=""
              width="16"
              height="16"
              hidden
            />
          </span>
          <svg
            class="account-menu__chevron"
            viewBox="0 0 24 24"
            width="16"
            height="16"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          ><path d="m6 9 6 6 6-6" /></svg>
        </summary>
        <div class="account-menu__panel">
          <p class="account-menu__label">{@account_control.label}</p>
          <.link href="/profile" class="account-menu__item">
            <.menu_icon name={:profile} /> Profile
          </.link>
          <.link href={@account_control.settings_path} class="account-menu__item">
            <.menu_icon name={:settings} /> Settings
          </.link>
          <button
            type="button"
            class="account-menu__item account-menu__item--leave"
            data-account-target="sign-out"
          >
            <.menu_icon name={:log_out} /> Log out
          </button>
        </div>
      </details>

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

  attr :name, :atom, required: true

  defp menu_icon(assigns) do
    ~H"""
    <svg
      class="account-menu__icon"
      viewBox="0 0 24 24"
      width="22"
      height="22"
      fill="none"
      stroke="currentColor"
      stroke-width="1.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <g :if={@name == :profile}>
        <circle cx="12" cy="12" r="9" />
        <circle cx="12" cy="10" r="3" />
        <path d="M6.5 18.5a6 6 0 0 1 11 0" />
      </g>
      <g :if={@name == :settings}>
        <circle cx="12" cy="12" r="3" />
        <path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.5 1.5M16.5 16.5 18 18M6 18l1.5-1.5M16.5 7.5 18 6" />
      </g>
      <g :if={@name == :log_out}>
        <path d="M10 4H5v16h5" />
        <path d="M14 8l5 4-5 4M19 12H9" />
      </g>
    </svg>
    """
  end
end
