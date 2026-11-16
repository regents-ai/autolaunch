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
  instead of each starting their own (`Cachex.fetch/4`), and a reading that
  fails is never kept. A step that lands (`changed/1`) leaves every reading
  taken before it behind, the one still being taken included, so the next ask
  takes a new one; and every open page of the product hears it (`subscribe/1`).
  The readings are kept on each machine, so on another machine a page reads
  anew once the one it holds is ten seconds old.
  """

  alias Autolaunch.Earn.Chain

  @cache :autolaunch_earn_terms

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

    case Cachex.fetch(@cache, {product.id, landed(product.id)}, read) do
      {kept, terms} when kept in [:ok, :commit] -> {:ok, terms}
      {:ignore, error} -> error
    end
  end

  @doc """
  A step on product `id` landed: the readings taken before it are left behind,
  and every open page of the product hears `{:earn_changed, id}`.
  """
  @spec changed(String.t()) :: :ok
  def changed(id) do
    {:ok, _landed} = Cachex.incr(@cache, {:landed, id})
    Phoenix.PubSub.broadcast(Autolaunch.PubSub, topic(id), {:earn_changed, id})
  end

  @doc "Hears `{:earn_changed, id}` each time a step on product `id` lands."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(id), do: Phoenix.PubSub.subscribe(Autolaunch.PubSub, topic(id))

  defp landed(id) do
    {:ok, landed} = Cachex.get(@cache, {:landed, id})
    landed || 0
  end

  defp topic(id), do: "earn:" <> id
end
