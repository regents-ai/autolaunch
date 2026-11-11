defmodule AutolaunchWeb.LiveListings do
  @moduledoc """
  Rereads a page's lists after a saved change to them (`Autolaunch.Listings`):
  one reread a second at most, however many changes arrive in it, so a busy
  launch reads the database once per page per second. The page keeps its
  filters, its place and any open bid form; only the records are read again.

  A change written inside a transaction that Ash did not start is published
  before that transaction commits; the second's wait lets the commit land
  before the reread.

  The auctions and tokens lists (`paged/1`) also keep their records here: read
  for the page's filters (`filtered/2`), a page more at a time (`load/2`), and
  read again in place, every loaded page at once (`reread/1`).
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, start_async: 3]
  import AutolaunchWeb.Components.AutolaunchHelpers, only: [creator_connections_for: 1]

  alias Autolaunch.HomeMarket

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
  def taken(socket) do
    :telemetry.execute([:autolaunch, :pages, :reread], %{count: 1}, %{view: socket.view})
    assign(socket, :listings_reread, nil)
  end

  @doc """
  A list page's records, empty until its first `filtered/2`, and subscribed to
  its listings' changes. The reads' answers land here, never in the page.
  """
  def paged(socket) do
    socket
    |> assign(
      options: nil,
      records: [],
      creators: %{},
      loading: true,
      failed: false,
      append: false,
      next_cursor: nil,
      has_more: false
    )
    |> subscribe()
    |> attach_hook(:listings, :handle_async, &answered/3)
  end

  @doc "Reads the list from its start for `options`, unless it already shows them."
  def filtered(%{assigns: %{options: options}} = socket, options), do: socket
  def filtered(socket, options), do: socket |> assign(:options, options) |> load(false)

  @doc "Reads the list from its start, or its next page with `append?`."
  def load(socket, append?) do
    %{options: options, next_cursor: next_cursor} = socket.assigns
    cursor = if append?, do: next_cursor

    socket =
      if append?, do: socket, else: assign(socket, records: [], has_more: false, next_cursor: nil)

    socket
    |> assign(loading: true, failed: false, append: append?)
    |> start_async(:listings, fn -> options |> HomeMarket.read(cursor) |> with_creators() end)
  end

  @doc "Takes the due reread: the records loaded so far, read again in place."
  def reread(socket) do
    %{options: options, records: records} = socket.assigns
    count = length(records)

    socket
    |> taken()
    |> start_async(:listings_reread, fn ->
      {options, count, options |> HomeMarket.reread(count) |> with_creators()}
    end)
  end

  defp answered(:listings, {:ok, {:ok, page}}, socket) do
    %{append: append, records: records, creators: creators} = socket.assigns

    {:halt,
     assign(socket,
       records:
         if(append, do: Enum.uniq_by(records ++ page.records, & &1.id), else: page.records),
       creators: if(append, do: Map.merge(creators, page.creators), else: page.creators),
       next_cursor: page.next_cursor,
       has_more: page.has_more,
       loading: false,
       failed: false
     )}
  end

  defp answered(:listings, _failure, socket),
    do: {:halt, assign(socket, loading: false, failed: true)}

  # A reread answers only for the list it was asked about, at the length it
  # had then; a filter, search or "Load more" since brings its own records. A
  # failed one leaves the list the reader already has.
  defp answered(:listings_reread, {:ok, {options, count, {:ok, page}}}, socket) do
    %{options: shown, records: records, loading: loading} = socket.assigns

    if options == shown and count == length(records) and not loading,
      do:
        {:halt,
         assign(socket,
           records: page.records,
           creators: page.creators,
           next_cursor: page.next_cursor,
           has_more: page.has_more
         )},
      else: {:halt, socket}
  end

  defp answered(:listings_reread, _failure, socket), do: {:halt, socket}
  defp answered(_name, _result, socket), do: {:cont, socket}

  # Each list row names its creator by their connected accounts.
  defp with_creators({:ok, page}),
    do: {:ok, Map.put(page, :creators, creator_connections_for(page.records))}

  defp with_creators(failure), do: failure
end
