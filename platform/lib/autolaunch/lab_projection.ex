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
  @chain_id 31_337
  @regent_decimals 18

  @doc "Projects one receipt-verified local launch as one replay-safe database unit."
  def project_launch(
        %{envelope: %{"chain_id" => @chain_id, "metadata" => %{"lab" => lab}} = envelope} =
          operation,
        result
      )
      when is_map(lab) and is_map(result) do
    arguments = envelope["arguments"]
    auction_id = auction_id(result["auction"])
    subject_id = subject_identity(result["subject"])

    transact(fn ->
      project_launch_records(
        envelope,
        arguments,
        result,
        auction_id,
        subject_id,
        Map.get(operation, :human_account_id)
      )
    end)
  end

  def project_launch(_operation, _result), do: :ok

  @doc "Projects one receipt-verified local bid and its exact on-chain bid id."
  def project_bid(%{envelope: envelope}, result) when is_map(result) do
    if lab_envelope?(envelope) do
      arguments = envelope["arguments"]
      bid_id = bid_identity(envelope["to"], result["onchain_bid_id"])

      transact(fn ->
        create(Bid, :project_lab, %{
          bid_id: bid_id,
          auction_id: arguments["auction_id"],
          owner_address: envelope["expected_signer"],
          amount: arguments["amount"],
          max_price: arguments["max_price"],
          current_clearing_price: result["current_clearing_price"] || "0",
          estimated_tokens_if_end_now: nil,
          status: "active",
          auction_address: envelope["to"],
          onchain_bid_id: result["onchain_bid_id"]
        })
      end)
    else
      :ok
    end
  end

  @doc "Applies one verified local position readback without changing production records."
  def project_position(%Bid{} = bid, result) when is_map(result) do
    transact(fn ->
      with {:ok, current_bid} <- read_bid_for_projection(bid.bid_id),
           {:ok, projected_bid} <-
             create(Bid, :project_lab, %{
               bid_id: current_bid.bid_id,
               auction_id: current_bid.auction_id,
               owner_address: current_bid.owner_address,
               amount: current_bid.amount,
               max_price: current_bid.max_price,
               current_clearing_price:
                 result["current_clearing_price"] || current_bid.current_clearing_price,
               estimated_tokens_if_end_now: current_bid.estimated_tokens_if_end_now,
               status: position_status(current_bid.status, result["bid_status"]),
               exited_at: transition_time(current_bid.exited_at, result, "exited"),
               claimed_at: transition_time(current_bid.claimed_at, result, "claimed"),
               auction_address: current_bid.auction_address,
               onchain_bid_id: current_bid.onchain_bid_id
             }),
           {:ok, auction} <- project_auction_state(current_bid.auction_id, result),
           {:ok, _subject} <- project_subject_state(result),
           {:ok, _launch} <- project_launch_state(current_bid.auction_id, result),
           {:ok, _token} <- maybe_project_token(auction, result) do
        {:ok, projected_bid}
      end
    end)
  end

  def auction_id(address) when is_binary(address), do: stable_uuid("auction:" <> address)

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

  defp project_auction_state(auction_id, result) do
    with {:ok, auction} <- read_auction(auction_id, true) do
      create(Auction, :project_lab, %{
        projection_id: auction.id,
        title: auction.title,
        summary: auction.summary,
        token_symbol: auction.token_symbol,
        website: auction.website,
        image: auction.image,
        creator_human_account_id: auction.creator_human_account_id,
        featured: auction.featured,
        state: auction_state(auction.state, result),
        opened_at: auction.opened_at,
        auction_address: auction.auction_address,
        quote_token_address: auction.quote_token_address,
        quote_token_symbol: auction.quote_token_symbol,
        quote_token_decimals: auction.quote_token_decimals,
        current_clearing_price:
          result["current_clearing_price"] || auction.current_clearing_price,
        treasury_address: auction.treasury_address
      })
    end
  end

  defp maybe_project_token(auction, %{"auction_state" => "graduated"} = result) do
    with {:ok, subject} <- read_subject(result["subject"]),
         {:ok, token} <- read_token(auction.id) do
      create(Token, :project_lab, %{
        auction_id: auction.id,
        subject_id: subject.subject_id,
        name: auction.title,
        symbol: auction.token_symbol,
        summary: auction.summary,
        graduated_at: if(token, do: token.graduated_at, else: DateTime.utc_now()),
        treasury_address: auction.treasury_address
      })
    end
  end

  defp maybe_project_token(_auction, _result), do: {:ok, nil}

  defp project_subject_state(%{"auction_state" => "graduated"} = result) do
    with {:ok, subject} <- read_subject(result["subject"]) do
      create(Subject, :project_lab, %{
        subject_id: subject.subject_id,
        subject_kind: subject.subject_kind,
        chain_id: subject.chain_id,
        token_address: subject.token_address,
        splitter_address: result["splitter"],
        ingress_address: subject.ingress_address,
        treasury_address: subject.treasury_address,
        canonical_receiver_address: result["receiver"],
        factory_address: subject.factory_address,
        creator_address: subject.creator_address,
        staker_pool_bps: subject.staker_pool_bps,
        protocol_skim_bps_snapshot: subject.protocol_skim_bps_snapshot,
        current_protocol_skim_bps: subject.current_protocol_skim_bps,
        protocol_fee_usdc_total_raw: subject.protocol_fee_usdc_total_raw,
        regent_emission_total_raw: subject.regent_emission_total_raw,
        pending_buyback_usdc_raw: subject.pending_buyback_usdc_raw
      })
    end
  end

  defp project_subject_state(_result), do: {:ok, nil}

  defp project_launch_state(auction_id, %{"auction_state" => state} = result)
       when state in ["graduated", "failed"] do
    with {:ok, launch} <- read_launch(auction_id) do
      create(LaunchJob, :project_lab, %{
        job_id: launch.job_id,
        status: if(state == "graduated", do: "complete", else: "failed"),
        step: if(state == "graduated", do: "graduated", else: "retired"),
        agent_id: launch.agent_id,
        agent_name: launch.agent_name,
        token_name: launch.token_name,
        token_symbol: launch.token_symbol,
        chain_id: launch.chain_id,
        auction_id: launch.auction_id,
        agent_safe_address: launch.agent_safe_address,
        auction_address: launch.auction_address,
        token_address: launch.token_address,
        hook_address: launch.hook_address,
        revenue_share_splitter_address: result["splitter"],
        treasury_address: launch.treasury_address,
        started_at: launch.started_at,
        finished_at: launch.finished_at || DateTime.utc_now()
      })
    end
  end

  defp project_launch_state(_auction_id, _result), do: {:ok, nil}

  defp read_auction(id, lock?) do
    Auction
    |> Ash.Query.for_read(:public_by_id, %{id: id}, domain: @domain, actor: nil)
    |> maybe_lock(lock?)
    |> Ash.read_one(domain: @domain, actor: nil)
    |> present(:auction_not_found)
  end

  defp read_bid_for_projection(bid_id) do
    Bid
    # System projection of a verified lab result; no actor.
    |> Ash.Query.for_read(:mine, %{}, domain: @domain, authorize?: false)
    |> Ash.Query.filter(bid_id == ^bid_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: @domain, authorize?: false)
    |> present(:bid_not_found)
  end

  defp read_subject(address) do
    Subject
    |> Ash.Query.for_read(
      :public_by_id,
      %{subject_id: subject_identity(address)},
      domain: @domain,
      actor: nil
    )
    |> Ash.read_one(domain: @domain, actor: nil)
    |> present(:subject_not_found)
  end

  defp read_launch(auction_id) do
    LaunchJob
    |> Ash.Query.new(domain: @domain)
    |> Ash.Query.filter(auction_id == ^auction_id)
    |> Ash.read_one(domain: @domain, actor: @actor)
    |> present(:launch_not_found)
  end

  defp read_token(auction_id) do
    Token
    |> Ash.Query.new(domain: @domain)
    |> Ash.Query.filter(auction_id == ^auction_id)
    |> Ash.read_one(domain: @domain, actor: @actor)
  end

  defp create(resource, action, attributes) do
    resource
    |> Ash.Changeset.for_create(action, attributes, domain: @domain, actor: @actor)
    |> Ash.create(domain: @domain, actor: @actor)
  end

  defp transact(callback) do
    case Ash.DataLayer.transaction(Auction, fn -> transaction_value(callback.()) end) do
      {:ok, _value} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp transaction_value({:ok, value}), do: value
  defp transaction_value({:error, error}), do: Ash.DataLayer.rollback(Auction, error)

  defp project_launch_records(
         envelope,
         arguments,
         result,
         auction_id,
         subject_id,
         human_account_id
       ) do
    with {:ok, auction} <-
           create(
             Auction,
             :project_lab,
             auction_attrs(arguments, %{
               projection_id: auction_id,
               creator_human_account_id: human_account_id,
               state: :active,
               auction_address: result["auction"],
               quote_token_address: arguments["regent"],
               treasury_address: result["treasury"]
             })
           ),
         {:ok, _subject} <-
           create(Subject, :project_lab, %{
             subject_id: subject_id,
             subject_kind: "regent",
             chain_id: @chain_id,
             token_address: result["subject"],
             ingress_address: result["escrow"],
             treasury_address: result["treasury"],
             factory_address: arguments["factory"],
             creator_address: envelope["expected_signer"]
           }),
         {:ok, _launch} <-
           create(LaunchJob, :project_lab, %{
             job_id: launch_identity(result["launch_id"]),
             status: "active",
             step: "auction",
             agent_id: subject_id,
             agent_name: arguments["name"],
             token_name: arguments["name"],
             token_symbol: arguments["symbol"],
             chain_id: @chain_id,
             auction_id: auction.id,
             agent_safe_address: result["treasury"],
             auction_address: result["auction"],
             token_address: result["subject"],
             hook_address: lab_address(envelope, "hook"),
             treasury_address: result["treasury"]
           }) do
      {:ok, auction}
    end
  end

  defp stable_uuid(value) do
    value
    |> String.downcase()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Ecto.UUID.load!()
  end

  defp lab_envelope?(%{"chain_id" => @chain_id, "metadata" => %{"lab" => lab}})
       when is_map(lab),
       do: true

  defp lab_envelope?(_envelope), do: false

  defp lab_address(envelope, key),
    do: get_in(envelope, ["metadata", "lab", "addresses", key])

  defp auction_state(state, _result) when state in [:graduated, :failed], do: state
  defp auction_state(_state, %{"auction_state" => "graduated"}), do: :graduated
  defp auction_state(_state, %{"auction_state" => "failed"}), do: :failed
  defp auction_state(state, _result), do: state

  defp position_status("claimed", _reported), do: "claimed"
  defp position_status(_current, "claimed"), do: "claimed"
  defp position_status("exited", _reported), do: "exited"
  defp position_status(_current, "exited"), do: "exited"
  defp position_status(current, _reported), do: current

  defp transition_time(existing, result, key) do
    if result[key] == true, do: existing || DateTime.utc_now(), else: existing
  end

  defp maybe_lock(query, true), do: Ash.Query.lock(query, :for_update)
  defp maybe_lock(query, false), do: query

  defp present({:ok, nil}, reason), do: {:error, reason}
  defp present(result, _reason), do: result
end
