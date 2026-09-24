defmodule Autolaunch.LabProjection do
  @moduledoc false

  require Ash.Query

  alias Autolaunch.Actors.System

  alias Autolaunch.{
    Auction,
    Bid,
    LaunchJob,
    Subject,
    Token
  }

  @actor %System{}
  @domain Autolaunch
  @regent_decimals 18

  @doc """
  Projects one receipt-verified launch as one replay-safe database unit.

  The auction row is written once (`Auction :record_launch`), by whichever
  confirmation of the launch comes first: the creator's browser report or
  launch discovery. A later confirmation finds that row and changes nothing,
  so it can never overwrite the launch's details or take its auction, subject
  or launch back to how they started.

  It runs inside the caller's transaction (the creator's session, or launch
  discovery), so nothing is announced here: it returns the listing
  notifications of the rows it wrote, for the caller to send once that
  transaction has committed. A launch already stored changed nothing and
  returns none.
  """
  def project_launch(%{envelope: envelope} = operation, result) when is_map(result) do
    arguments = envelope["arguments"]

    transaction(fn ->
      arguments
      |> auction_attrs(%{
        chain_id: envelope["chain_id"],
        origin: :site,
        creator_human_account_id: Map.get(operation, :human_account_id),
        state: :created,
        auction_address: result["auction"],
        quote_token_address: arguments["regent"],
        required_currency_raised: arguments["required_regent_raised_atomic"],
        treasury_address: result["treasury"],
        treasury_security_report_id: arguments["treasury_security"]["report_id"]
      })
      |> Autolaunch.record_launch_auction(actor: @actor, return_notifications?: true)
      |> project_launch_records(envelope, arguments, result)
    end)
  end

  @doc "Projects one receipt-verified bid and its exact on-chain bid id."
  def project_bid(%{envelope: envelope}, result) when is_map(result) do
    arguments = envelope["arguments"]
    auction_address = arguments["auction_address"]
    bid_id = bid_identity(auction_address, result["onchain_bid_id"])

    # The committed amount comes from the verified result: the reviewed amount
    # for a direct bid, the adapter's reported STOCK for a USDC bid.
    transact(fn ->
      create(Bid, :project_lab, %{
        bid_id: bid_id,
        auction_id: arguments["auction_id"],
        owner_address: envelope["expected_signer"],
        amount: result["amount"],
        max_price: arguments["max_price"],
        current_clearing_price: result["current_clearing_price"] || "0",
        estimated_tokens_if_end_now: nil,
        status: "active",
        auction_address: auction_address,
        onchain_bid_id: result["onchain_bid_id"]
      })
    end)
  end

  @doc """
  Projects one verified settlement step onto the bid position it settled.

  A verified exit records the refund and the fill and leaves the position
  `claimable` when the reviewed sequence continues with a claim, `returned`
  otherwise; a verified claim records the tokens delivered and marks it
  `claimed`.
  """
  def project_settlement(%{envelope: envelope}, step, result)
      when step in [:exit, :claim] and is_map(result) do
    arguments = envelope["arguments"]
    claim_next? = Enum.any?(arguments["steps"], &(&1["step"] == "claim"))

    transact(fn ->
      with {:ok, current} <- read_bid_for_projection(arguments["bid_id"]) do
        create(Bid, :project_lab, %{
          bid_id: current.bid_id,
          auction_id: current.auction_id,
          owner_address: current.owner_address,
          amount: current.amount,
          max_price: current.max_price,
          current_clearing_price: current.current_clearing_price,
          estimated_tokens_if_end_now: current.estimated_tokens_if_end_now,
          status: settled_status(step, result, claim_next?),
          exited_at: current.exited_at || DateTime.utc_now(),
          claimed_at: if(step == :claim, do: current.claimed_at || DateTime.utc_now()),
          auction_address: current.auction_address,
          onchain_bid_id: current.onchain_bid_id,
          currency_refunded: result["currency_refunded_units"] || current.currency_refunded,
          tokens_filled: result["tokens_filled_units"] || current.tokens_filled,
          tokens_claimed: result["tokens_claimed_units"] || current.tokens_claimed
        })
      end
    end)
  end

  @doc """
  Projects the `Token` row of an auction the market feed has just seen graduate.

  An Agent token keeps the subject the launch projection recorded; a Stocks
  token has no Agent subject. The upsert is replay-safe on the auction, so
  projecting the same graduation again changes nothing here.
  """
  def project_graduated_token(%Auction{state: :graduated} = auction) do
    with {:ok, subject_id} <- token_subject(auction),
         {:ok, token} <- read_token(auction.id),
         {:ok, _token} <-
           create(Token, :project_lab, %{
             auction_id: auction.id,
             subject_id: subject_id,
             name: auction.title,
             symbol: auction.token_symbol,
             summary: auction.summary,
             graduated_at: if(token, do: token.graduated_at, else: DateTime.utc_now()),
             treasury_address: auction.treasury_address
           }) do
      :ok
    end
  end

  def project_graduated_token(_auction), do: :ok

  @doc """
  Stores the pool price a market feed just read for an auction's token, and
  says whether it moved. `nil` before the pool has a price, or for an auction
  without a token row yet, changes nothing.
  """
  @spec project_token_price(String.t(), String.t() | nil) :: {:ok, boolean()} | {:error, term()}
  def project_token_price(_auction_id, nil), do: {:ok, false}

  def project_token_price(auction_id, price_quote) when is_binary(price_quote) do
    case read_token(auction_id) do
      {:ok, %Token{price_quote: ^price_quote}} ->
        {:ok, false}

      {:ok, %Token{} = token} ->
        with {:ok, _token} <-
               Autolaunch.set_subject_token_price(
                 token,
                 price_quote,
                 "pool",
                 DateTime.utc_now(),
                 actor: @actor
               ),
             do: {:ok, true}

      {:ok, nil} ->
        {:ok, false}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp token_subject(%Auction{kind: :stocks}), do: {:ok, nil}

  defp token_subject(%Auction{kind: :agent, id: auction_id}) do
    with {:ok, launch} <- read_launch(auction_id), do: {:ok, launch.agent_id}
  end

  @doc false
  def auction_attrs(arguments, overrides) when is_map(arguments) and is_map(overrides) do
    Map.merge(
      %{
        title: arguments["name"],
        summary: arguments["description"],
        token_symbol: arguments["symbol"],
        website: arguments["website"],
        image: arguments["image"],
        featured: false,
        quote_token_symbol: "REGENT",
        quote_token_decimals: @regent_decimals,
        current_clearing_price: "0"
      },
      overrides
    )
  end

  def subject_identity(address) when is_binary(address),
    do: "lab:" <> (address |> String.downcase() |> String.trim_leading("0x"))

  def launch_identity(launch_id), do: "lab:" <> to_string(launch_id)

  def bid_identity(address, bid_id),
    do:
      "lab:" <>
        (address |> String.downcase() |> String.trim_leading("0x")) <>
        ":" <> to_string(bid_id)

  defp read_bid_for_projection(bid_id) do
    Bid
    # System projection of a verified lab result; no actor.
    |> Ash.Query.for_read(:mine, %{}, domain: @domain, authorize?: false)
    |> Ash.Query.filter(bid_id == ^bid_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: @domain, authorize?: false)
    |> present(:bid_not_found)
  end

  defp read_launch(auction_id) do
    LaunchJob
    |> Ash.Query.new(domain: @domain)
    |> Ash.Query.filter(auction_id == ^auction_id)
    |> Ash.read_one(domain: @domain, actor: @actor)
    |> present(:launch_not_found)
  end

  defp read_token(auction_id),
    do: Autolaunch.get_token_for_projection(auction_id, actor: @actor)

  defp create(resource, action, attributes) do
    resource
    |> Ash.Changeset.for_create(action, attributes, domain: @domain, actor: @actor)
    |> Ash.create(domain: @domain, actor: @actor)
  end

  # The same write, returning its notifications for the caller to send after
  # commit instead of sending them.
  defp create_quietly(resource, action, attributes) do
    resource
    |> Ash.Changeset.for_create(action, attributes, domain: @domain, actor: @actor)
    |> Ash.create(domain: @domain, actor: @actor, return_notifications?: true)
  end

  # One Ash transaction, so pages hear of these writes only once they are
  # committed, and a failed write saves nothing.
  defp transact(write) do
    with {:ok, _value} <- transaction(write), do: :ok
  end

  defp transaction(write), do: Ash.transaction(Auction, fn -> commit(write.()) end)

  defp commit({:ok, value}), do: value
  defp commit({:error, reason}), do: Ash.DataLayer.rollback(Auction, reason)

  # A row another confirmation already wrote carries its subject and launch,
  # and nothing about it changed.
  defp project_launch_records(
         {:ok, %Auction{__metadata__: %{upsert_skipped: true}}, _notifications},
         _envelope,
         _arguments,
         _result
       ),
       do: {:ok, []}

  defp project_launch_records({:ok, auction, notifications}, envelope, arguments, result) do
    subject_id = subject_identity(result["subject"])

    with {:ok, _subject, subject_notifications} <-
           create_quietly(Subject, :project_lab, %{
             subject_id: subject_id,
             subject_kind: "regent",
             chain_id: envelope["chain_id"],
             token_address: result["subject"],
             ingress_address: result["escrow"],
             treasury_address: result["treasury"],
             factory_address: arguments["factory"],
             creator_address: envelope["expected_signer"]
           }),
         {:ok, _launch, launch_notifications} <-
           create_quietly(LaunchJob, :project_lab, %{
             job_id: launch_identity(result["launch_id"]),
             status: "active",
             step: "auction",
             agent_id: subject_id,
             agent_name: arguments["name"],
             token_name: arguments["name"],
             token_symbol: arguments["symbol"],
             chain_id: envelope["chain_id"],
             auction_id: auction.id,
             agent_safe_address: result["treasury"],
             auction_address: result["auction"],
             token_address: result["subject"],
             hook_address: lab_address(envelope, "hook"),
             treasury_address: result["treasury"]
           }),
         do: {:ok, notifications ++ subject_notifications ++ launch_notifications}
  end

  defp project_launch_records(error, _envelope, _arguments, _result), do: error

  defp lab_address(envelope, key),
    do: get_in(envelope, ["metadata", "lab", "addresses", key])

  defp settled_status(:claim, _result, _claim_next?), do: "claimed"

  defp settled_status(:exit, %{"tokens_filled" => filled}, true) when filled != "0",
    do: "claimable"

  defp settled_status(:exit, _result, _claim_next?), do: "returned"

  defp present({:ok, nil}, reason), do: {:error, reason}
  defp present(result, _reason), do: result
end
