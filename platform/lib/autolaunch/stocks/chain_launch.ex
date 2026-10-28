defmodule Autolaunch.Stocks.ChainLaunch do
  @moduledoc """
  Lists a Base Memestock launch that no review of this site carried out, from
  the chain alone: every Memestock launch on Base is listed, wherever it was
  sent (Sean, 28 Oct 2026). Its creator is the wallet that sent it, with no
  account, and its auction row has origin `:chain`.

  Everything such a launch carries was written by whoever sent it and passed
  none of the create page's checks, so it is kept only as those checks keep a
  draft's: the name, ticker and description as text, with anything that is
  not text taken out and the name and ticker on one line; the ticker only
  when it keeps to the site's rule (`Autolaunch.Ticker`), or the launch is not
  listed; the website only when it is a full https:// link
  (`Autolaunch.LaunchLinks.web_link?/1`); and the picture only when it is one
  this site stores (`Autolaunch.StoredImage`), so a page shows the token's
  first letter for any other. The pages escape all of it as they escape every
  launch's text.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.{LabAbi, LaunchLinks, StoredImage, Ticker}
  alias Autolaunch.Stocks.{Assets, LaunchActions}

  @actor %System{}
  @transient [:chain_unavailable, :invalid_chain_response]
  # Control characters other than a line break, every invisible format
  # character (zero-width spaces and joiners, reordering marks, soft hyphens,
  # tag characters), every character Unicode says a page may draw as nothing
  # (variation selectors, combining joiners, fillers) and the blank braille
  # cell, any of which could make a name read as another.
  @hidden ~r/(?!\n)[\p{Cc}\p{Cf}\p{Default_Ignorable_Code_Point}\x{2800}]/u
  # Line and paragraph separators, and carriage returns, read as line breaks.
  @breaks ~r/\r\n?|[\p{Zl}\p{Zp}]/u

  @type answer ::
          {:listed, nil, map()}
          | {:unlisted, :invalid_metadata | :launchpad_retired}
          | {:pending, term()}

  @doc """
  Lists the launch `discovery` records under its launching wallet:
  `{:listed, nil, result}` once its auction row is written (or already was),
  `{:unlisted, :invalid_metadata}` when what it carries can never make a row
  (a ticker the site's rule refuses, `Autolaunch.Ticker`, or no name at all),
  `{:unlisted, :launchpad_retired}` for a launch on a launchpad this site no
  longer runs, or `{:pending, reason}` while the chain cannot be read.
  """
  @spec list(map()) :: answer()
  def list(%{chain_id: chain_id, contract: contract} = discovery) do
    case Enum.find(
           Launchpads.configured(),
           &(&1.launchpad == :base_memestock and &1.chain_id == chain_id and
               &1.contract == contract)
         ) do
      nil -> {:unlisted, :launchpad_retired}
      pad -> list(pad, discovery.launch_id)
    end
  end

  defp list(pad, launch_id) do
    with {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, launch} <- read(pad, launch_id, block),
         # The launchpad launches only an admitted stock, and the site saves
         # every stock it ever admitted (`Autolaunch.Stocks.Stock.SyncAdmissions`
         # reads each `StockAdmitted`), so a stock not saved yet is one the next
         # sync saves: the launch waits for it.
         {:ok, stock} <- Assets.fetch(Assets.stock_chain_id(pad), launch.stock),
         {:ok, row} <- row(pad, launch, stock) do
      record(row)
    else
      {:error, :invalid_metadata} -> {:unlisted, :invalid_metadata}
      {:error, reason} -> {:pending, reason}
    end
  end

  defp read(pad, launch_id, block) do
    with {:ok, words} <-
           Rpc.call_words(
             pad.contract,
             LabAbi.encode(pad.abi, "launches(uint256)", [launch_id]),
             block,
             pad.shape.record_words,
             pad.opts
           ),
         record = pad.records.record(pad.shape, words),
         {:ok, launcher} <- address(record.launcher),
         {:ok, token} <- address(record.new_token),
         {:ok, stock} <- address(record.stock),
         {:ok, auction} <- address(record.auction),
         {:ok, name} <- token_bytes(pad, token, "name()", block),
         {:ok, symbol} <- token_bytes(pad, token, "symbol()", block),
         {:ok, metadata} <- metadata(pad, token, block) do
      {:ok,
       %{
         launcher: launcher,
         token: token,
         stock: stock,
         auction: auction,
         name: name,
         symbol: symbol,
         metadata: metadata
       }}
    end
  end

  # The token's `tokenURI()` is a base64 JSON object holding only the
  # metadata fields the launch filled in.
  defp metadata(pad, token, block) do
    with {:ok, "data:application/json;base64," <> encoded} <-
           token_string(pad, token, "tokenURI()", block),
         {:ok, json} <- Base.decode64(encoded),
         # The token keeps the launch's bytes as they were sent, so text that is
         # not valid is cleaned here as a name's is.
         {:ok, %{} = metadata} <- json |> String.replace_invalid("") |> Jason.decode() do
      {:ok, metadata}
    else
      {:error, reason} when reason in @transient -> {:error, reason}
      _malformed -> {:error, :invalid_metadata}
    end
  end

  defp row(pad, launch, stock) do
    symbol = line(launch.symbol)
    title = line(launch.name) || symbol

    if title && Ticker.complete?(symbol) do
      {:ok,
       %{
         kind: :stocks,
         origin: :chain,
         featured: false,
         current_clearing_price: "0",
         chain_id: pad.chain_id,
         auction_address: launch.auction,
         token_address: launch.token,
         creator_human_account_id: nil,
         creator_address: launch.launcher,
         title: title,
         summary: text(launch.metadata["description"]),
         token_symbol: symbol,
         website: website(launch.metadata["website"]),
         image: image(launch.metadata["image"]),
         quote_token_address: stock.address,
         quote_token_symbol: stock.symbol,
         quote_token_decimals: stock.decimals,
         required_currency_raised: Integer.to_string(LaunchActions.required_stock_raised()),
         state: :created,
         # Every raised stock goes to the launchpad, the only custody a launch has.
         treasury_address: pad.contract
       }}
    else
      {:error, :invalid_metadata}
    end
  end

  # A row already written, by this or by the creator's own review, is kept as it is.
  defp record(row) do
    case Autolaunch.record_launch_auction(row, actor: @actor) do
      {:ok, auction} -> {:listed, nil, %{"auction" => auction.auction_address}}
      {:error, %Ash.Error.Invalid{}} -> {:unlisted, :invalid_metadata}
      {:error, reason} -> {:pending, reason}
    end
  end

  @doc """
  Text a launch carries, as a page may show it: valid, with nothing hidden in
  it and line breaks only as line breaks, or nil.
  """
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) do
    value
    |> String.replace_invalid("")
    |> String.replace(@breaks, "\n")
    |> String.replace(@hidden, "")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  def text(_value), do: nil

  @doc "A name or ticker a launch carries: its text on one line, or nil."
  @spec line(term()) :: String.t() | nil
  def line(value) do
    case text(value) do
      nil -> nil
      text -> String.replace(text, ~r/\s+/u, " ")
    end
  end

  @doc "A launch's website, kept only when it is a full https:// link with no space of any kind in it."
  @spec website(term()) :: String.t() | nil
  def website(value) do
    case text(value) do
      nil -> nil
      link -> if LaunchLinks.web_link?(link) and not (link =~ ~r/[\s\p{Z}]/u), do: link
    end
  end

  @doc "A launch's picture, kept only when it is an image this site stores, at this site's address."
  @spec image(term()) :: String.t() | nil
  def image(value) when is_binary(value) do
    with true <- String.starts_with?(value, AutolaunchWeb.Endpoint.url() <> "/"),
         {:ok, _key} <- StoredImage.key(value),
         {:ok, _bytes} <- StoredImage.bytes(value) do
      value
    else
      _other -> nil
    end
  end

  def image(_value), do: nil

  defp token_string(pad, token, signature, block),
    do: Rpc.call_string(token, LabAbi.selector(signature), block, pad.opts)

  defp token_bytes(pad, token, signature, block),
    do: Rpc.call_bytes(token, LabAbi.selector(signature), block, pad.opts)

  defp address(word) do
    case Abi.word_address(word) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :invalid_chain_response}
    end
  end
end
