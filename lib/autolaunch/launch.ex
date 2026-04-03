defmodule Autolaunch.Launch do
  @moduledoc false

  alias Autolaunch.Launch.{Agents, Auctions, Bids, Jobs, Preview}

  defdelegate fee_split_summary(), to: Agents
  defdelegate chain_options(), to: Agents
  defdelegate record_world_agentbook_completion(launch_job_id, attrs), to: Agents
  defdelegate list_agents(human), to: Agents
  defdelegate get_agent(human, agent_id), to: Agents
  defdelegate controls_agent?(human, agent_id), to: Agents
  defdelegate launch_readiness_for_agent(human, agent_id), to: Agents

  defdelegate preview_launch(attrs, human), to: Preview
  defdelegate create_launch_job(attrs, human, request_ip), to: Preview

  defdelegate get_job_response(job_id, owner_address \\ nil), to: Jobs
  defdelegate queue_processing(job_id), to: Jobs
  defdelegate terminal_status?(status), to: Jobs
  defdelegate process_job(job_id), to: Jobs

  defdelegate list_auctions(filters \\ %{}, current_human \\ nil), to: Auctions
  defdelegate list_auction_returns(filters \\ %{}, current_human \\ nil), to: Auctions
  defdelegate get_auction(auction_id, current_human \\ nil), to: Auctions

  defdelegate quote_bid(auction_id, attrs, current_human \\ nil), to: Bids
  defdelegate place_bid(auction_id, attrs, human), to: Bids
  defdelegate list_positions(human, filters \\ %{}), to: Bids
  defdelegate exit_bid(bid_id, attrs, human), to: Bids
  defdelegate return_bid(bid_id, attrs, human), to: Bids
  defdelegate claim_bid(bid_id, attrs, human), to: Bids
end
