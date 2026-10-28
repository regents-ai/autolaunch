defmodule Autolaunch.Stocks.ChainLaunch do
  @moduledoc """
  Lists a Base Memestock launch that no review of this site carried out, from
  the chain alone: every Memestock launch on Base is listed, wherever it was
  sent (Sean, 28 Oct 2026). Its creator is the wallet that sent it, with no
  account, and its auction row has origin `:chain`.

  Everything such a launch carries was written by whoever sent it and passed
  none of the create page's checks, so it is kept only as those checks keep a
  draft's: the name, ticker and description as text, with anything that is
  not text taken out; the website only when it is a full https:// link
  (`Autolaunch.LaunchLinks.web_link?/1`); and the picture only when it is one
  this site stores (`Autolaunch.StoredImage`), so a page shows the token's
  first letter for any other. The pages escape all of it as they escape every
  launch's text.
  """

  alias Autolaunch.Actors.System
  alias Autolaunch.AuctionFinish.Launchpads
  alias Autolaunch.Chain.{Abi, Rpc}
  alias Autolaunch.{LabAbi, LaunchLinks, StoredImage}
  alias Autolaunch.Stocks.{Assets, LaunchActions}

  @actor %System{}
  @transient [:chain_unavailable, :invalid_chain_response]
  # Control characters other than a line break, and the marks that reorder
  # the text around them, which could make a name read as another.
  @hidden ~r/[\x{0000}-\x{0009}\x{000B}-\x{001F}\x{007F}-\x{009F}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  @type answer :: {:listed, nil, map()} | {:unlisted, :invalid_metadata} | {:pending, term()}

  @doc """
  Lists the launch `discovery` records under its launching wallet:
  `{:listed, nil, result}` once its auction row is written (or already was),
  `{:unlisted, :invalid_metadata}` when what it carries can never make a row,
  or `{:pending, reason}` while the chain cannot be read.
  """
  @spec list(map()) :: answer()
  def list(%{launch_id: launch_id} = discovery) do
    pad = Launchpads.for_launch!(discovery)

    with {:ok, block} <- Rpc.latest_block(pad.opts),
         {:ok, launch} <- read(pad, launch_id, block),
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
         {:ok, name} <- token_string(pad, token, "name()", block),
         {:ok, symbol} <- token_string(pad, token, "symbol()", block),
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
         {:ok, %{} = metadata} <- Jason.decode(json) do
      {:ok, metadata}
    else
      {:error, reason} when reason in @transient -> {:error, reason}
      _malformed -> {:ok, %{}}
    end
  end

  defp row(pad, launch, stock) do
    symbol = text(launch.symbol)
    title = text(launch.name) || symbol

    if title && symbol do
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

  @doc "Text a launch carries, as a page may show it: valid, with nothing hidden in it, or nil."
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) do
    value
    |> String.replace_invalid("")
    |> String.replace(@hidden, "")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  def text(_value), do: nil

  @doc "A launch's website, kept only when it is a full https:// link."
  @spec website(term()) :: String.t() | nil
  def website(value) do
    case text(value) do
      nil -> nil
      link -> if LaunchLinks.web_link?(link), do: link
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

  defp address(word) do
    case Abi.word_address(word) do
      {:ok, address} -> {:ok, address}
      :error -> {:error, :invalid_chain_response}
    end
  end
end
