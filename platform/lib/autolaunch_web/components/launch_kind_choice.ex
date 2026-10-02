defmodule AutolaunchWeb.Components.LaunchKindChoice do
  @moduledoc "The choice between the two launches, at the top of both Create pages."
  use AutolaunchWeb, :html

  attr :current, :atom, required: true, values: [:memestake, :revstake]
  attr :design, :atom, default: :current, values: [:current, :next]

  @doc "Memestake or Revstake, as links to each Create page, with the open one marked."
  def launch_kind_choice(assigns) do
    ~H"""
    <nav class="launch-kind" aria-label="Launch type">
      <.link
        navigate={if @design == :next, do: ~p"/next/create", else: ~p"/create"}
        class="launch-kind__option"
        data-squish
        aria-current={@current == :memestake && "page"}
      >
        <strong>Memestake</strong>
        <span>Pairing a memecoin with a real stock is called a memestock.</span>
      </.link>
      <.link
        navigate={if @design == :next, do: ~p"/next/create/revstake", else: ~p"/create/revstake"}
        class="launch-kind__option"
        data-squish
        aria-current={@current == :revstake && "page"}
      >
        <strong>Revstake</strong>
        <span>Tokenize a stablecoin generating service or agent.</span>
      </.link>
    </nav>
    """
  end
end
