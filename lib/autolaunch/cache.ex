defmodule Autolaunch.Cache do
  @moduledoc false

  @spec fetch(String.t(), pos_integer(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, ttl_seconds, fun), do: RegentCache.fetch(:autolaunch, key, ttl_seconds, fun)

  @spec get_json(String.t()) :: {:ok, term()} | :miss | {:error, term()}
  def get_json(key), do: RegentCache.get_json(:autolaunch, key)

  @spec put_json(String.t(), term(), pos_integer()) :: :ok | {:error, term()}
  def put_json(key, value, ttl_seconds),
    do: RegentCache.put_json(:autolaunch, key, value, ttl_seconds)

  @spec delete(String.t() | [String.t()]) :: :ok | {:error, term()}
  def delete(keys), do: RegentCache.delete(:autolaunch, keys)

  @spec digest(term()) :: String.t()
  def digest(value), do: RegentCache.digest(value)
end
