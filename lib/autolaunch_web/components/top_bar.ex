defmodule AutolaunchWeb.Components.TopBar do
  @moduledoc false
  use Phoenix.Component

  import AutolaunchWeb.Components.AccountControl

  attr :account_control, Autolaunch.AccessContext.AccountControl, required: true

  def top_bar(assigns) do
    ~H"""
    <header class="shell-top">
      <form class="shell-search" action="/" method="get" role="search">
        <label class="shell-search__label" for="shell-search-q">Search</label>
        <input
          id="shell-search-q"
          class="shell-search__input"
          type="search"
          name="q"
          placeholder="Search auctions and tokens"
          autocomplete="off"
        />
      </form>
      <.account_control account_control={@account_control} />
    </header>
    """
  end
end
