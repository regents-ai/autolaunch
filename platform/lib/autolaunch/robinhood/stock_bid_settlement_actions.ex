defmodule Autolaunch.Robinhood.StockBidSettlementActions do
  @moduledoc """
  The one boundary between a bidder's wallet and the end of a Robinhood
  memestock auction: returning what a bid did not spend, and claiming the
  launch tokens it won.

  Preparation reads Robinhood and returns the whole reviewed sequence as a
  single immutable envelope: the exit the auction accepts for this bid (a plain
  exit, or a partial exit with the checkpoint hints the auction needs when the
  bid was only partly filled), then the claim when there is one. Nothing is
  written anywhere. The chain is the only record: confirmation reads the
  canonical receipt through `Autolaunch.Robinhood.StockBidSettlementChainClient`.

  Every call binds to the signed-in wallet of the account the session lease
  names, read inside the lease at call time, and the bid must belong to that
  wallet on the auction's own record.
  """

  alias Autolaunch.Accounts.SessionAuthority
  alias Autolaunch.Actors.Human
  alias Autolaunch.Chain.{Address, Envelope, Rpc}
  alias Autolaunch.Robinhood.{Lab, StockBidSettlementChainClient}
  alias Autolaunch.Stocks.{Amounts, Assets, LaunchOperations}

  @resource "autolaunch_robinhood_bid_settlement"
  @action "autolaunch_robinhood_bid_settlement"
  @contract_name "IContinuousClearingAuction"
  @new_decimals 18
  @transient [:chain_unavailable, :invalid_chain_response, :transaction_missing]

  @doc """
  Reviews the settlement of one bid for the signed-in wallet: one snapshot at
  one pinned block, one immutable envelope, the reviewed steps and the plain
  facts the page shows. Refused, with the auction's own reason, when nothing
  can be done for the bid right now.
  """
  @spec prepare(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%{auction: auction, bid_id: bid_id}, address, opts) do
    with {:ok, actor} <- human(opts),
         {:ok, signer} <- current_wallet(address, actor, opts),
         {:ok, _config} <- robinhood_lab(),
         {:ok, auction} <- address(auction, :invalid_auction),
         {:ok, bid_id} <- bid_id(bid_id),
         {:ok, snapshot} <- snapshot(auction, bid_id, signer),
         :ok <- owned(snapshot, signer),
         {:ok, asset} <- listed_stock(snapshot.stock),
         {:ok, steps} <- eligible_steps(snapshot),
         do: {:ok, build(steps, asset, signer, snapshot)}
  end

  @doc """
  Reads one sent step back from the chain for the signed-in wallet. The result
  is the chain client's own answer: `:pending`, `:reverted`, `:unverified`, or
  `:confirmed` with the auction's record of what was returned or claimed.
  """
  @spec verify(map(), :exit | :claim, String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(envelope, step, hash, opts) when is_map(envelope) and step in [:exit, :claim] do
    with {:ok, actor} <- human(opts),
         {:ok, _signer} <- current_wallet(envelope["expected_signer"], actor, opts),
         {:ok, hash} <- canonical_hash(hash),
         {:ok, _config} <- robinhood_lab(),
         true <- valid_envelope?(envelope) || unavailable(:envelope_invalid),
         do: read_chain(envelope, step, hash)
  end

  def verify(_envelope, _step, _hash, _opts), do: unavailable(:unknown_step)

  # Inputs

  defp bid_id(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp bid_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id >= 0 -> {:ok, id}
      _other -> unavailable(:bid_not_found)
    end
  end

  defp bid_id(_value), do: unavailable(:bid_not_found)

  defp owned(%{bid: %{owner: owner}}, signer) do
    if Address.equal?(owner, signer), do: :ok, else: unavailable(:not_your_bid)
  end

  defp listed_stock(stock) do
    case Assets.fetch(Lab.chain_id(), stock) do
      {:ok, asset} -> {:ok, asset}
      _missing -> unavailable(:stock_not_listed)
    end
  end

  # The steps the auction accepts right now: the exit first, then the claim
  # when one is open; a bid already returned may only claim.
  defp eligible_steps(%{exit: {:refused, :already_exited}, claim: %{} = claim}),
    do: {:ok, [claim_step(claim)]}

  defp eligible_steps(%{exit: %{} = exit, claim: claim}),
    do: {:ok, [exit_step(exit) | claim_steps(claim)]}

  defp eligible_steps(snapshot), do: unavailable(refusal_reason(snapshot))

  defp refusal_reason(%{exit: {:refused, :already_exited}, claim: {:refused, reason}}), do: reason
  defp refusal_reason(%{exit: {:refused, reason}}), do: reason

  defp claim_steps(%{} = claim), do: [claim_step(claim)]
  defp claim_steps({:refused, _reason}), do: []

  defp exit_step(exit) do
    %{
      "step" => "exit",
      "signature" => exit.signature,
      "data" => exit.data,
      "hints" => hints(exit.hints),
      "tokens_filled" => Integer.to_string(exit.tokens_filled),
      "stock_refunded" => Integer.to_string(exit.currency_refunded)
    }
  end

  defp claim_step(claim) do
    %{
      "step" => "claim",
      "signature" => "claimTokens(uint256)",
      "data" => claim.data,
      "tokens_claimed" => Integer.to_string(claim.tokens_claimed)
    }
  end

  defp hints(nil), do: nil

  defp hints(hints) do
    %{
      "last_fully_filled_block" => Integer.to_string(hints.last_fully_filled_block),
      "outbid_block" => Integer.to_string(hints.outbid_block)
    }
  end

  # The review

  defp build(steps, asset, signer, snapshot) do
    steps = Enum.map(steps, &Map.put(&1, "to", snapshot.auction))
    exit = Enum.find(steps, &(&1["step"] == "exit"))
    claim = Enum.find(steps, &(&1["step"] == "claim"))
    decimals = snapshot.stock_decimals

    envelope =
      @action
      |> Envelope.new(signer, steps |> hd() |> Map.fetch!("data"),
        to: snapshot.auction,
        resource: @resource,
        contract_name: @contract_name,
        chain_id: Lab.chain_id(),
        lab_binding: snapshot.lab_binding,
        risk_copy: risk_copy(exit, claim, asset),
        arguments: %{
          "onchain_bid_id" => Integer.to_string(snapshot.bid.id),
          "auction" => snapshot.auction,
          "stock" => snapshot.stock,
          "stock_symbol" => asset.symbol,
          "stock_decimals" => Integer.to_string(decimals),
          "bid_amount_atomic" => Integer.to_string(snapshot.bid.amount),
          "bid_amount_units" => Rpc.format_units(snapshot.bid.amount, decimals),
          "max_price_q96" => Integer.to_string(snapshot.bid.max_price_q96),
          "max_price" => price(snapshot.bid.max_price_q96, decimals),
          "final_clearing_price_q96" => Integer.to_string(snapshot.final_clearing_price_q96),
          "final_clearing_price" => price(snapshot.final_clearing_price_q96, decimals),
          "graduated" => snapshot.graduated?,
          "end_block" => Integer.to_string(snapshot.end_block),
          "claim_block" => Integer.to_string(snapshot.claim_block),
          "stock_refunded_units" =>
            exit && Rpc.format_units(integer(exit, "stock_refunded"), decimals),
          "tokens_filled_units" =>
            exit && Rpc.format_units(integer(exit, "tokens_filled"), @new_decimals),
          "tokens_claimed_units" =>
            claim && Rpc.format_units(integer(claim, "tokens_claimed"), @new_decimals),
          "block_number" => snapshot.block.number,
          "block_hash" => snapshot.block.hash,
          "steps" => steps
        }
      )
      |> stored()

    %{envelope: envelope, steps: steps, review: review(envelope["arguments"])}
  end

  # The plain facts the page shows before anything is signed.
  defp review(arguments) do
    symbol = arguments["stock_symbol"]

    Enum.reject(
      [
        [
          "Bid",
          "#{compact(arguments["bid_amount_units"])} #{symbol} at up to #{compact(arguments["max_price"])} #{symbol} per token"
        ],
        ["Final price", "#{compact(arguments["final_clearing_price"])} #{symbol} per token"],
        ["Outcome", outcome_copy(arguments)],
        arguments["stock_refunded_units"] &&
          ["Comes back to you", "#{compact(arguments["stock_refunded_units"])} #{symbol}"],
        arguments["tokens_filled_units"] &&
          ["Tokens won", "#{compact(arguments["tokens_filled_units"])} tokens"],
        arguments["tokens_claimed_units"] &&
          ["Tokens claimable now", "#{compact(arguments["tokens_claimed_units"])} tokens"]
      ],
      &(&1 in [nil, false])
    )
  end

  defp outcome_copy(%{"graduated" => true}),
    do: "The launch raised enough. Tokens are on their way."

  defp outcome_copy(_arguments),
    do: "The launch did not raise enough. Every bid is returned in full."

  defp risk_copy(exit, claim, asset) do
    parts =
      Enum.reject(
        [
          exit && "returns your unspent #{asset.symbol} from this auction",
          claim && "delivers your launch tokens"
        ],
        &is_nil/1
      )

    network =
      if Lab.test_chain?(),
        do: "the local Robinhood lab. Test assets have no mainnet value.",
        else: "Robinhood Chain (chain #{Lab.chain_id()})."

    "Your wallet signs a transaction that #{Enum.join(parts, ", then one that ")} on #{network}"
  end

  defp price(q96, decimals), do: Amounts.format_cca_price(q96, decimals, @new_decimals)

  defp compact(value), do: Amounts.compact_decimal(value)

  defp integer(step, key), do: step |> Map.fetch!(key) |> String.to_integer()

  defp stored(envelope), do: envelope |> Jason.encode!() |> Jason.decode!()

  # Confirmation

  defp valid_envelope?(envelope) do
    Envelope.valid_for_confirmation?(envelope,
      resource: @resource,
      action: @action,
      signer: envelope["expected_signer"],
      contract_name: @contract_name,
      chain_id: Lab.chain_id()
    )
  end

  defp read_chain(envelope, step, hash) do
    case StockBidSettlementChainClient.verify(envelope, step, hash) do
      {:ok, result} -> {:ok, result}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # Chain snapshot

  defp robinhood_lab do
    case Lab.current() do
      {:ok, config} -> {:ok, config}
      {:error, _reason} -> unavailable(:robinhood_unavailable)
    end
  end

  defp snapshot(auction, bid_id, signer) do
    case StockBidSettlementChainClient.snapshot(%{
           auction: auction,
           bid_id: bid_id,
           signer: signer
         }) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} when reason in @transient -> unavailable(:chain_unavailable)
      {:error, reason} -> unavailable(reason)
    end
  end

  # Session and wallet identity

  defp human(opts) do
    case Keyword.get(opts, :actor) do
      %Human{} = actor -> {:ok, actor}
      _anonymous -> unavailable(:authentication_required)
    end
  end

  defp lease(opts) do
    case Keyword.get(opts, :context) do
      %{session_lease: %{lineage: lineage, account_id: account_id}}
      when is_binary(lineage) and is_integer(account_id) ->
        {:ok, %{lineage: lineage, account_id: account_id}}

      _absent ->
        unavailable(:session_lease_required)
    end
  end

  # The wallet the page presents has to be the signed-in wallet of the leased
  # account, read now: not another linked address, and never a guess.
  defp current_wallet(address, actor, opts) do
    with {:ok, candidate} <- address(address, :invalid_address),
         {:ok, lease} <- lease(opts),
         {:ok, account} <- leased(lease),
         :ok <- same_account(actor, account),
         do: signed_in_wallet(account, candidate)
  end

  defp leased(%{lineage: lineage, account_id: account_id}) do
    case SessionAuthority.leased_account(lineage, account_id) do
      nil -> unavailable(:session_unavailable)
      account -> {:ok, account}
    end
  end

  defp same_account(%Human{human_account_id: id}, %{id: id}), do: :ok
  defp same_account(_actor, _account), do: unavailable(:session_unavailable)

  defp signed_in_wallet(%{wallet_address: wallet}, candidate) when is_binary(wallet) do
    if Address.equal?(wallet, candidate), do: {:ok, candidate}, else: unavailable(:wrong_signer)
  end

  defp signed_in_wallet(_account, _candidate), do: unavailable(:wrong_signer)

  # Shared helpers

  defp canonical_hash(hash) do
    if Rpc.valid_hash?(hash), do: {:ok, String.downcase(hash)}, else: unavailable(:invalid_hash)
  end

  defp address(value, reason) do
    case Address.normalize(value) do
      {:ok, address} -> {:ok, address}
      :error -> unavailable(reason)
    end
  end

  defp unavailable(reason), do: LaunchOperations.unavailable(reason)
end
