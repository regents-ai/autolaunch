defmodule Autolaunch.AgentAccount do
  @moduledoc """
  What a paired agent reads and saves for the person it acts for, as the
  hosted MCP tools run it: the launch draft of each kind and its save, the
  person's bids and holdings, and their Points. Each action gives the `data` of
  the answer its signed route gives, or Points' whole answer, which has no
  `data` (`AutolaunchWeb.AccountAnswer`), and the route's refusal as its own.
  Nothing is kept here; a draft save writes the person's draft as its route
  does (`Autolaunch.AgentDrafts`), and in prelaunch read-only mode refuses as
  its route does (`AutolaunchWeb.Prelaunch.refusal/0`). The person still
  reviews the draft and signs its launch on the create page.

  Only a paired agent runs these. An app connected to a person's account runs
  them as its paired agent, never as itself.
  """

  use Ash.Resource,
    otp_app: :autolaunch,
    domain: Autolaunch,
    authorizers: [Ash.Policy.Authorizer]

  alias AutolaunchWeb.{AccountAnswer, ApiError}

  # Text goes to the draft as the route takes it: untrimmed, empty included.
  @text [allow_empty?: true, trim?: false]

  actions do
    # Null before the person has a draft of this kind.
    action :revstake_draft, :map do
      allow_nil? true
      run fn _input, %{actor: actor} -> ApiError.data(AccountAnswer.draft("revstake", actor)) end
    end

    action :revstake_draft_save, :map do
      argument :name, :string, constraints: @text
      argument :symbol, :string, constraints: @text
      argument :description, :string, constraints: @text
      argument :website, :string, constraints: @text
      argument :telegram, :string, constraints: @text
      argument :discord, :string, constraints: @text
      argument :other_link_1, :string, constraints: @text
      argument :other_link_2, :string, constraints: @text
      argument :other_link_3, :string, constraints: @text
      argument :treasury, :string, constraints: @text
      argument :treasury_path, :atom, constraints: [one_of: [:safe, :contract, :eoa]]
      argument :image, :map

      run fn input, %{actor: actor} -> __MODULE__.save("revstake", input.arguments, actor) end
    end

    action :memestock_draft, :map do
      allow_nil? true
      run fn _input, %{actor: actor} -> ApiError.data(AccountAnswer.draft("memestock", actor)) end
    end

    action :memestock_draft_save, :map do
      argument :name, :string, constraints: @text
      argument :symbol, :string, constraints: @text
      argument :description, :string, constraints: @text
      argument :website, :string, constraints: @text
      argument :telegram, :string, constraints: @text
      argument :discord, :string, constraints: @text
      argument :other_link_1, :string, constraints: @text
      argument :other_link_2, :string, constraints: @text
      argument :other_link_3, :string, constraints: @text
      argument :chain, :atom, constraints: [one_of: [:base, :robinhood]]
      argument :stock_address, :string, constraints: @text
      argument :image, :map

      run fn input, %{actor: actor} -> __MODULE__.save("memestock", input.arguments, actor) end
    end

    action :my_positions, :map do
      run fn _input, %{actor: actor} -> ApiError.data(AccountAnswer.positions(actor)) end
    end

    action :points, :map do
      run fn _input, %{actor: actor} -> AccountAnswer.points(actor) end
    end
  end

  @doc false
  def save(kind, arguments, actor) do
    if Autolaunch.Prelaunch.read_only?(),
      do: {:error, AutolaunchWeb.Prelaunch.refusal()},
      else:
        kind
        |> AccountAnswer.save_draft(AccountAnswer.draft_params(arguments), actor)
        |> ApiError.data()
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:role, :agent)
    end
  end
end
