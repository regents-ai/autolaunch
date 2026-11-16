defmodule Autolaunch.Earn.SharedTerms do
  @moduledoc """
  Each product's market as one reading every visitor shares: the page and its
  Refresh, `GET /api/v1/earn/products` and the agent tools all read it
  (`Autolaunch.Earn.Product`'s `:terms`). A reading is kept for ten seconds
  (`:earn_terms_kept_ms`; 0 keeps nothing, as the tests run), and wherever it
  is shown it names the block it was read at, so it never passes for a newer
  one. A position, a quote and a step's build read the chain at the latest
  block every time.

  Visitors who ask while a reading is being taken wait for that one reading
  instead of each starting their own (`Cachex.fetch/4`). A reading that fails
  is never kept, and one that cannot be taken or kept because of the cache
  itself is refused as `:chain_unavailable`.

  A step that lands is counted once for each transaction (`changed/2`): the
  first report of it leaves every reading taken before it behind, the one
  still being taken included, and tells every open page of the product
  `{:earn_changed, id, hash}`; a later report of the same transaction does
  neither, so it cannot be replayed to make every page read the chain again.
  The readings are kept on each machine, and a page on another machine that
  hears of the step marks it there the same way before it reads (`heard/2`),
  so it never gets a reading from before it. A machine with no page of the
  product open hears nothing, and its kept reading is at most ten seconds old.
  """

  require Logger

  alias Autolaunch.Earn.Chain

  @cache :autolaunch_earn_terms

  # How long each machine remembers a landed transaction: far longer than a
  # reading is kept, so a report of the same transaction again finds it.
  @landed_kept_ms :timer.hours(1)

  @doc "The cache the readings are kept in (`Autolaunch.Application`)."
  def cache, do: @cache

  @doc "The shared reading of `product`'s market on `lab`."
  @spec read(map(), map()) :: {:ok, Chain.terms()} | {:error, atom()}
  def read(product, lab) do
    case Application.fetch_env!(:autolaunch, :earn_terms_kept_ms) do
      0 -> latest(product, lab)
      kept_ms -> kept(product, lab, kept_ms)
    end
  end

  defp latest(product, lab) do
    with {:ok, terms, nil} <- Chain.read(product, lab, nil), do: {:ok, terms}
  end

  # One reading for each product and each step landed on it: a step that
  # lands moves every later ask to a reading of its own.
  defp kept(product, lab, kept_ms) do
    read = fn ->
      case latest(product, lab) do
        {:ok, terms} -> {:commit, terms, expire: kept_ms}
        error -> {:ignore, error}
      end
    end

    with {:ok, landed} <- landed(product.id) do
      case Cachex.fetch(@cache, {product.id, landed}, read) do
        {kept, terms} when kept in [:ok, :commit] -> {:ok, terms}
        {:ignore, error} -> error
        {:error, _fault} -> {:error, :chain_unavailable}
      end
    end
  end

  defp landed(id) do
    case Cachex.get(@cache, {:landed, id}) do
      {:ok, landed} -> {:ok, landed || 0}
      {:error, _fault} -> {:error, :chain_unavailable}
    end
  end

  @doc """
  Transaction `hash` landed a step on product `id`. The first report of it
  leaves the readings taken before it behind and tells every open page of the
  product `{:earn_changed, id, hash}`; any later report of it does neither.
  When the cache cannot count it, that is logged and the pages are still told.
  """
  @spec changed(String.t(), String.t()) :: :ok
  def changed(id, hash) do
    if mark(id, hash) == :known,
      do: :ok,
      else: Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic(id), {:earn_changed, id, hash})
  end

  @doc """
  A page heard `{:earn_changed, id, hash}`, perhaps from another machine: the
  step is counted on this one too, once, so the page's next reading is taken
  after it. The first page on a machine to hear it counts it; the rest find it
  counted.
  """
  @spec heard(String.t(), String.t()) :: :ok
  def heard(id, hash) do
    _counted = mark(id, hash)
    :ok
  end

  @doc "Hears `{:earn_changed, id, hash}` each time a step on product `id` lands."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(id), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(id))

  # Marks `hash` landed on product `id` on this machine and moves later
  # readers on to a new reading, in one step under the mark's lock, so a page
  # that finds the mark already reads after the move: `:new` the first time,
  # `:known` after, `:fault` when the cache could do neither.
  defp mark(id, hash) do
    marked =
      Cachex.get_and_update(@cache, {:landed, id, hash}, fn
        nil ->
          case Cachex.incr(@cache, {:landed, id}) do
            {:ok, _landed} -> {:commit, true, expire: @landed_kept_ms}
            {:error, fault} -> {:ignore, {:error, fault}}
          end

        true ->
          {:ignore, true}
      end)

    case marked do
      {:commit, true} -> :new
      {:ignore, true} -> :known
      {:ignore, {:error, fault}} -> fault(id, fault)
      {:error, fault} -> fault(id, fault)
    end
  end

  defp fault(id, fault) do
    Logger.warning(
      "autolaunch earn landed step not counted #{inspect(%{product: id, fault: fault})}"
    )

    :fault
  end

  defp topic(id), do: "earn:" <> id
end
