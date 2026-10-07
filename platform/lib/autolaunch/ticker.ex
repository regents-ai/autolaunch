defmodule Autolaunch.Ticker do
  @moduledoc """
  The site's rule for a launch's ticker: capital letters A to Z and numbers,
  up to ten. A ticker another listed launch already uses is allowed; the
  create pages only say so.
  """

  @complete ~r/\A[A-Z0-9]{1,10}\z/
  @partial ~r/\A[A-Z0-9]{0,10}\z/

  @doc "What the ticker field says when a ticker breaks the rule."
  def hint, do: "Use capital letters and numbers, up to 10"

  @doc "Whether `symbol` is a whole ticker."
  def complete?(symbol), do: is_binary(symbol) and symbol =~ @complete

  @doc "Whether `symbol` keeps to the rule so far; an empty ticker does."
  def partial?(symbol), do: is_binary(symbol) and symbol =~ @partial

  @doc "Whether a listed launch already uses `symbol`, in any case."
  def taken?(symbol) do
    complete?(symbol) and
      match?({:ok, [_ | _]}, Autolaunch.list_path_peers([String.downcase(symbol)], actor: nil))
  end
end
