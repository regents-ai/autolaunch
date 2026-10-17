defmodule AutolaunchWeb.Components.Loading do
  @moduledoc """
  What a page shows while it is still reading something after it opened: the
  shape of what is coming, in the site's one card, so nothing jumps when it
  arrives. Screen readers hear what is being read; the blocks are hidden from
  them. The look is `.loading-block` in `assets/css/components/surfaces.css`.
  """
  use Phoenix.Component

  attr :label, :string,
    required: true,
    doc: ~s(What is being read, as a screen reader hears it, such as "Reading your points".)

  attr :shape, :atom,
    default: :lines,
    values: [:lines, :figures],
    doc: "Lines of text in one card, or a row of figures each in its own card."

  attr :id, :string, default: nil

  def placeholder(%{shape: :figures} = assigns) do
    ~H"""
    <div id={@id} class="loading-figures" role="status">
      <span class="visually-hidden">{@label}</span>
      <span :for={_figure <- 1..3} class="loading-figures__figure" aria-hidden="true">
        <span class="loading-block loading-figures__label"></span>
        <span class="loading-block loading-figures__value"></span>
      </span>
    </div>
    """
  end

  def placeholder(assigns) do
    ~H"""
    <div id={@id} class="loading-card" role="status">
      <span class="visually-hidden">{@label}</span>
      <span class="loading-block loading-card__title" aria-hidden="true"></span>
      <span :for={_line <- 1..3} class="loading-block loading-card__line" aria-hidden="true"></span>
    </div>
    """
  end
end
