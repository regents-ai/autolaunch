defmodule Autolaunch.Dragonfly do
  @moduledoc false

  @spec enabled?() :: boolean()
  def enabled?, do: RegentCache.Dragonfly.enabled?(:autolaunch)

  @spec status() :: :disabled | :ready | {:error, term()}
  def status, do: RegentCache.Dragonfly.status(:autolaunch)

  @spec command([term()]) :: {:ok, term()} | {:error, term()}
  def command(command), do: RegentCache.Dragonfly.command(:autolaunch, command)

  @spec get(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def get(key), do: RegentCache.Dragonfly.get(:autolaunch, key)

  @spec set(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  def set(key, value, ttl_seconds),
    do: RegentCache.Dragonfly.set(:autolaunch, key, value, ttl_seconds)

  @spec delete(String.t() | [String.t()]) :: :ok | {:error, term()}
  def delete(keys), do: RegentCache.Dragonfly.delete(:autolaunch, keys)
end
