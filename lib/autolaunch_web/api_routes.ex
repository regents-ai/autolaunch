defmodule AutolaunchWeb.ApiRoutes do
  @moduledoc false

  defmacro product_api_routes(opts \\ []) do
    include_app_staking_prepare? = Keyword.get(opts, :include_app_staking_prepare?, false)

    quote do
      get "/agents", AgentController, :index
      get "/agents/:id", AgentController, :show
      get "/agents/:id/readiness", AgentController, :readiness
      get "/trust/agents/:id", TrustController, :show_agent
      post "/trust/x/start", TrustController, :start_x
      post "/trust/x/callback", TrustController, :complete_x

      get "/subjects/:id", SubjectController, :show
      get "/subjects/:id/ingress", SubjectController, :ingress
      post "/subjects/:id/stake", SubjectController, :stake
      post "/subjects/:id/unstake", SubjectController, :unstake
      post "/subjects/:id/claim-usdc", SubjectController, :claim_usdc
      post "/subjects/:id/claim-emissions", SubjectController, :claim_emissions

      post "/subjects/:id/claim-and-stake-emissions",
           SubjectController,
           :claim_and_stake_emissions

      post "/subjects/:id/ingress/:address/sweep", SubjectController, :sweep_ingress

      get "/regent/staking", RegentStakingController, :show
      get "/regent/staking/account/:address", RegentStakingController, :account
      post "/regent/staking/stake", RegentStakingController, :stake
      post "/regent/staking/unstake", RegentStakingController, :unstake
      post "/regent/staking/claim-usdc", RegentStakingController, :claim_usdc
      post "/regent/staking/claim-regent", RegentStakingController, :claim_regent

      post "/regent/staking/claim-and-restake-regent",
           RegentStakingController,
           :claim_and_restake_regent

      if unquote(include_app_staking_prepare?) do
        post "/regent/staking/deposit-usdc/prepare", RegentStakingController, :prepare_deposit

        post "/regent/staking/withdraw-treasury/prepare",
             RegentStakingController,
             :prepare_withdraw_treasury
      end

      get "/prelaunch/plans", PrelaunchController, :index
      post "/prelaunch/plans", PrelaunchController, :create
      get "/prelaunch/plans/:id", PrelaunchController, :show
      patch "/prelaunch/plans/:id", PrelaunchController, :update
      post "/prelaunch/plans/:id/validate", PrelaunchController, :validate
      post "/prelaunch/plans/:id/publish", PrelaunchController, :publish
      post "/prelaunch/plans/:id/launch", PrelaunchController, :launch
      post "/prelaunch/assets", PrelaunchController, :upload_asset
      post "/prelaunch/plans/:id/metadata", PrelaunchController, :metadata
      get "/prelaunch/plans/:id/metadata-preview", PrelaunchController, :metadata_preview

      get "/lifecycle/jobs/:id", LifecycleController, :show_job
      post "/lifecycle/jobs/:id/finalize/prepare", LifecycleController, :prepare_finalize
      post "/lifecycle/jobs/:id/finalize/register", LifecycleController, :register_finalize
      get "/lifecycle/jobs/:id/vesting", LifecycleController, :vesting

      get "/contracts/admin", ContractsController, :admin
      get "/contracts/jobs/:id", ContractsController, :show_job
      get "/contracts/subjects/:id", ContractsController, :show_subject
      post "/contracts/jobs/:id/:resource/:action/prepare", ContractsController, :prepare_job

      post "/contracts/subjects/:id/:resource/:action/prepare",
           ContractsController,
           :prepare_subject

      post "/contracts/admin/:resource/:action/prepare", ContractsController, :prepare_admin

      post "/launch/preview", LaunchController, :preview
      post "/launch/jobs", LaunchController, :create_job
      get "/launch/jobs/:id", LaunchController, :show_job

      get "/auctions", AuctionController, :index
      get "/auction-returns", AuctionController, :returns
      get "/auctions/:id", AuctionController, :show
      get "/me/profile", MeController, :profile
      post "/me/profile/refresh", MeController, :refresh_profile
      get "/me/holdings", MeController, :holdings
      post "/auctions/:id/bid_quote", AuctionController, :bid_quote
      post "/auctions/:id/bids", AuctionController, :create_bid
      get "/me/bids", MeController, :bids

      post "/bids/:id/return-usdc", BidController, :return_usdc
      post "/bids/:id/exit", BidController, :exit
      post "/bids/:id/claim", BidController, :claim

      post "/ens/link/plan", EnsLinkController, :plan
      post "/ens/link/prepare-ensip25", EnsLinkController, :prepare_ensip25
      post "/ens/link/prepare-erc8004", EnsLinkController, :prepare_erc8004
      post "/ens/link/prepare-bidirectional", EnsLinkController, :prepare_bidirectional
    end
  end
end
