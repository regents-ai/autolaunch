defmodule AutolaunchWeb.Motion do
  @moduledoc """
  Autolaunch's standard motion: the version of each kind of movement, the same
  on every Regent site and kept in the template's motion lab. The shared kit in
  `assets/js/motion.ts` and `assets/js/hooks/motion/` moves presses, menus and
  dialogs on every page; a live part names its version from here in
  `data-variant`.
  """

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
end
