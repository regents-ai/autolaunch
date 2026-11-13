defmodule AutolaunchWeb.Motion do
  @moduledoc """
  Autolaunch's standard motion: the version of each kind of movement, the same
  on every Regent site and shown beside the others in the motion lab at
  `/animations`. The shared kit in
  `assets/js/motion.ts` and `assets/js/hooks/motion/` moves presses, menus and
  dialogs on every page; a live part names its version from here in
  `data-variant`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @standard %{
    "drawer" => "spring",
    "sheet" => "spring",
    "menu" => "pop",
    "note" => "peel",
    "toast" => "pop",
    "list" => "bounce",
    "count" => "roll",
    "stamp" => "thunk",
    "tabs" => "glide",
    "headline" => "rise",
    "grid" => "cascade"
  }

  @doc "Every part's standard version."
  def standard, do: @standard

  @doc "The standard version of one part, such as `\"toast\"`."
  def standard(part), do: Map.fetch!(@standard, part)

  @doc """
  The attributes that make an element open as a panel of `kind`: a `"menu"`
  under its button, or a `"sheet"`, a dialog rising from below. A live page
  leaves the style the motion writes alone while it plays, along with any
  attributes in `keep`, such as a dialog's `open`.
  """
  def panel(kind, keep \\ []) when kind in ["menu", "sheet"] do
    %{
      "data-panel" => kind,
      "phx-mounted" => JS.ignore_attributes(keep ++ ["style"])
    }
  end

  attr :rest, :global

  @doc """
  A tick in the colour of the text around it, hidden from screen readers, so
  the words beside it say what is done. Inside a wallet step with the
  `MotionStep` hook, it draws itself in when the step lands. A live page
  leaves its line alone while it draws.
  """
  def tick(assigns) do
    ~H"""
    <svg class="motion-tick" viewBox="0 0 24 24" aria-hidden="true" {@rest}>
      <path pathLength="1" d="M4 12.5l5 5L20 6.5" phx-mounted={JS.ignore_attributes("style")} />
    </svg>
    """
  end
end
