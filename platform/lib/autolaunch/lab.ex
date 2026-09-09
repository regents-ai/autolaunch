defmodule Autolaunch.Lab do
  @moduledoc false

  alias Autolaunch.Chain.Address
  alias Autolaunch.{ChainMode, LabRpcUrl}

  @chain_id 31_337
  # 1 / 2^96 = 5^96 / 10^96, so a Q96 price is an exact 96-place decimal.
  @five_pow_96 Integer.pow(5, 96)
  @address_keys ~w(
    cca_factory
    escrow_implementation
    factory
    governance_safe
    hook
    permit2
    pool_manager
    position_manager
    receiver_implementation
    regent
    splitter_implementation
    strategy
    uerc20_factory
  )
  @abi_keys ~w(auction escrow factory hook permit2 receiver splitter strategy token)

  @type t :: %{
          path: String.t(),
          run_id: String.t(),
          rpc_url: String.t(),
          public_rpc_url: String.t(),
          chain_id: pos_integer(),
          addresses: %{required(String.t()) => String.t()},
          abis: %{required(String.t()) => [map()]}
        }

  def enabled?, do: Application.get_env(:autolaunch, :autolaunch_lab_enabled, false) == true

  def current do
    if enabled?() do
      with {:ok, config} <-
             Application.fetch_env!(:autolaunch, :autolaunch_lab_config_path)
             |> load(),
           run_id when is_binary(run_id) and run_id != "" <-
             Application.get_env(:autolaunch, :autolaunch_lab_run_id) do
        {:ok, Map.put(config, :run_id, run_id)}
      else
        nil -> {:error, :missing_acceptance_run}
        "" -> {:error, :missing_acceptance_run}
        {:error, reason} -> {:error, reason}
        _invalid -> {:error, :missing_acceptance_run}
      end
    else
      {:error, :lab_disabled}
    end
  end

  def current! do
    case current() do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch lab configuration is unavailable: #{reason}"
    end
  end

  def load!(path, mode \\ ChainMode.mode()) do
    case load(path, mode) do
      {:ok, config} -> config
      {:error, reason} -> raise "Autolaunch lab configuration is invalid: #{reason}"
    end
  end

  @doc """
  Reads and validates `site-config.json` for a chain mode.

  `rpc_url` is the site's own door and must be admitted for the mode
  (`Autolaunch.LabRpcUrl.admitted/2`); `public_rpc_url` is the door wallets
  add and is required in fork mode (`Autolaunch.LabRpcUrl.public/3`).
  """
  def load(path, mode \\ ChainMode.mode())

  def load(path, mode) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         # Founder-supplied startup input; this path never comes from an HTTP request.
         # sobelow_skip ["Traversal.FileModule"]
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, rpc_url} <- LabRpcUrl.admitted(decoded["rpc_url"], mode),
         {:ok, public_rpc_url} <- LabRpcUrl.public(decoded["public_rpc_url"], rpc_url, mode),
         @chain_id <- decoded["chain_id"],
         {:ok, addresses} <- exact_addresses(decoded["addresses"]),
         {:ok, abis} <- exact_abis(decoded["abis"]),
         :ok <- Autolaunch.LabAbi.validate(abis) do
      {:ok,
       %{
         path: path,
         rpc_url: rpc_url,
         public_rpc_url: public_rpc_url,
         chain_id: @chain_id,
         addresses: addresses,
         abis: abis
       }}
    else
      false -> {:error, :absolute_path_required}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :enoent} -> {:error, :missing_file}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_shape}
    end
  end

  def load(_path, _mode), do: {:error, :absolute_path_required}

  @doc """
  The lab binding an envelope carries to the browser. Its `rpc_url` is the
  public door, the one a wallet adds as chain 31337; the site's own `rpc_url`
  never leaves the server.
  """
  def binding(
        %{
          run_id: run_id,
          public_rpc_url: public_rpc_url,
          chain_id: chain_id,
          addresses: addresses
        },
        keys
      )
      when is_list(keys) do
    %{
      "run_id" => run_id,
      "rpc_url" => public_rpc_url,
      "chain_id" => chain_id,
      "addresses" => Map.take(addresses, Enum.map(keys, &to_string/1))
    }
  end

  def full_binding(%{run_id: run_id} = config) do
    %{
      run_id: run_id,
      path: config.path,
      rpc_url: config.rpc_url,
      public_rpc_url: config.public_rpc_url,
      chain_id: config.chain_id,
      addresses: config.addresses,
      abis: config.abis
    }
  end

  def binding_matches?(binding, keys) when is_map(binding) and is_list(keys) do
    case current() do
      {:ok, config} -> binding(config, keys) == stringify(binding)
      {:error, _reason} -> false
    end
  end

  @doc "The exact decimal a Q96 fixed-point price names: `q96 / 2^96`, with no rounding."
  def price_decimal(q96) when is_integer(q96) and q96 >= 0, do: plain(q96 * @five_pow_96, -96)

  # Drops trailing zeros by hand: `Decimal.normalize/1` would round the
  # coefficient to the context precision, and a Q96 price has more digits.
  defp plain(0, _exp), do: Decimal.new(0)
  defp plain(coef, exp) when rem(coef, 10) == 0, do: plain(div(coef, 10), exp + 1)
  defp plain(coef, exp), do: Decimal.new(1, coef, exp)

  @doc "`price_decimal/1` as the plain decimal string the site stores and shows."
  def format_price(q96), do: q96 |> price_decimal() |> Decimal.to_string(:normal)

  def address!(config, key), do: Map.fetch!(config.addresses, to_string(key))
  def abi!(config, key), do: Map.fetch!(config.abis, to_string(key))
  def chain_id, do: @chain_id

  defp exact_addresses(addresses) when is_map(addresses) do
    with true <- Enum.sort(Map.keys(addresses)) == Enum.sort(@address_keys),
         true <- Enum.all?(addresses, fn {_key, value} -> valid_address?(value) end) do
      {:ok, Map.new(addresses, fn {key, value} -> {key, String.downcase(value)} end)}
    else
      _ -> {:error, :invalid_addresses}
    end
  end

  defp exact_addresses(_addresses), do: {:error, :invalid_addresses}

  defp exact_abis(abis) when is_map(abis) do
    with true <- Enum.sort(Map.keys(abis)) == Enum.sort(@abi_keys),
         true <- Enum.all?(abis, fn {_key, value} -> is_list(value) and value != [] end) do
      {:ok, abis}
    else
      _ -> {:error, :invalid_abis}
    end
  end

  defp exact_abis(_abis), do: {:error, :invalid_abis}

  defp valid_address?(value), do: match?({:ok, _address}, Address.normalize(value))

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)
  end

  defp stringify(value), do: value
end
