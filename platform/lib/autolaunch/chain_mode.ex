defmodule Autolaunch.ChainMode do
  @moduledoc """
  Which chain a build of the site runs against: `:base` (real Base; the
  production site) or `:fork` (a hosted Base fork carrying the lab contract
  graph, for a public preview).

  `config/runtime.exs` sets `:chain_mode` from `AUTOLAUNCH_CHAIN_MODE`; the
  variable admits exactly `base` (the default when unset) and `fork`. Fork mode
  requires both lab configurations, admits a private non-loopback RPC for the
  site's own reads and sends, requires a separate public RPC for wallets, and
  serves with writes open.
  """

  @modes [:base, :fork]

  @type t :: :base | :fork

  @spec mode() :: t()
  def mode, do: Application.fetch_env!(:autolaunch, :chain_mode)

  @spec fork?() :: boolean()
  def fork?, do: mode() == :fork

  @doc "The fork this site runs against, as every page names it."
  @spec label() :: String.t()
  def label, do: label(mode())

  @spec label(t()) :: String.t()
  def label(:fork), do: "Preview on a Base fork"
  def label(:base), do: "Local Base fork"

  @doc "The value of `AUTOLAUNCH_CHAIN_MODE`; unset means `base`, anything else stops the boot."
  @spec parse!(String.t() | nil) :: t()
  def parse!(nil), do: :base
  def parse!(""), do: :base
  def parse!("base"), do: :base
  def parse!("fork"), do: :fork

  def parse!(other) do
    raise ArgumentError,
          "AUTOLAUNCH_CHAIN_MODE must be base or fork, got #{inspect(other)}; " <>
            "admitted: #{Enum.map_join(@modes, ", ", &Atom.to_string/1)}"
  end

  @doc """
  Whether the site boots read-only for a chain mode. Fork mode carries deployed
  contracts, so it serves with writes open; base mode leaves the fail-closed
  prelaunch default in force.
  """
  @spec prelaunch_read_only?(t()) :: boolean()
  def prelaunch_read_only?(:fork), do: false
  def prelaunch_read_only?(:base), do: true

  @doc """
  `AUTOLAUNCH_FAUCET_COOLDOWN_SECONDS` for a chain mode: a non-negative integer,
  `0` meaning no cooldown. Unset means 3600 in fork mode and 0 in base mode.
  """
  @spec faucet_cooldown_seconds!(t(), String.t() | nil) :: non_neg_integer()
  def faucet_cooldown_seconds!(mode, nil), do: default_faucet_cooldown(mode)
  def faucet_cooldown_seconds!(mode, ""), do: default_faucet_cooldown(mode)

  def faucet_cooldown_seconds!(_mode, value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        seconds

      _invalid ->
        raise ArgumentError,
              "AUTOLAUNCH_FAUCET_COOLDOWN_SECONDS must be a non-negative integer, got #{inspect(value)}"
    end
  end

  defp default_faucet_cooldown(:fork), do: 3_600
  defp default_faucet_cooldown(:base), do: 0
end
