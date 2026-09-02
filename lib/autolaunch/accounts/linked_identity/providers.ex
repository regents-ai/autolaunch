defmodule Autolaunch.Accounts.LinkedIdentity.Providers do
  @moduledoc false

  @providers [
    %{provider: :github, label: "GitHub"},
    %{provider: :farcaster, label: "Farcaster"}
  ]

  def all, do: @providers

  def profile_url(:x, username), do: build_profile_url("https://x.com/", username)
  def profile_url(:github, username), do: build_profile_url("https://github.com/", username)

  def profile_url(:farcaster, username),
    do: build_profile_url("https://farcaster.xyz/", username)

  def profile_url(_provider, _username), do: nil

  def handle(%{provider: :github, username: username}), do: present(username)

  def handle(%{username: username}) do
    case present(username) do
      nil -> nil
      username -> "@#{username}"
    end
  end

  defp build_profile_url(_base, username) when not is_binary(username), do: nil

  defp build_profile_url(base, username) do
    case String.trim(username) do
      "" -> nil
      username -> base <> URI.encode_www_form(username)
    end
  end

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil
end
