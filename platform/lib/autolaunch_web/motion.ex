defmodule AutolaunchWeb.Motion do
  @moduledoc """
  Autolaunch's standard motion, the same as Patchbay's: the version of each
  kind of movement the pages use. Presses move the same way on every page from
  `assets/js/motion/page.ts`; a menu, dialog or toast names its version from
  here. Parts Autolaunch has no place for yet keep their standard version
  here, so a new one starts from it.
  """

  alias Phoenix.LiveView.JS

  @standard %{
    "drawer" => "spring",
    "sheet" => "spring",
    "menu" => "pop",
    "dialog" => "pop",
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
  The attributes that make an element open as a panel of `kind`, `"menu"` or
  `"dialog"`. A live page leaves the motion's own attributes alone while it
  plays, along with any in `keep`, such as a dialog's `open`.
  """
  def panel(kind, keep \\ []) when kind in ["menu", "dialog"] do
    %{
      "data-panel" => kind,
      "data-variant" => standard(kind),
      "phx-mounted" => JS.ignore_attributes(keep ++ ["style", "data-opening", "data-closing"])
    }
  end
end
