defmodule AutolaunchWeb.LiveListings do
  @moduledoc """
  Rereads a page's lists after a saved change to them (`Autolaunch.Listings`):
  one reread a second at most, however many changes arrive in it, so a busy
  launch reads the database once per page per second. The page keeps its
  filters, its place and any open bid form; only the records are read again.

  A change written inside a transaction that Ash did not start is published
  before that transaction commits; the second's wait lets the commit land
  before the reread.
  """

  import Phoenix.Component, only: [assign: 3]

  @delay_ms 1_000

  def subscribe(socket) do
    if Phoenix.LiveView.connected?(socket), do: Autolaunch.Listings.subscribe()
    assign(socket, :listings_reread, nil)
  end

  @doc "Schedules one `:reread_listings` message unless one is already due."
  def schedule(%{assigns: %{listings_reread: nil}} = socket),
    do: assign(socket, :listings_reread, Process.send_after(self(), :reread_listings, @delay_ms))

  def schedule(socket), do: socket

  @doc "Marks the due reread as taken, so the next change schedules another."
  def taken(socket), do: assign(socket, :listings_reread, nil)
end
