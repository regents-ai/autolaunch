defmodule Autolaunch.Accounts.VerifiedSession do
  @moduledoc "Establishes the shared Regent account from verified Privy evidence."

  require Ash.Query
  alias Ash.Error.Changes.InvalidAttribute
  alias Autolaunch.Accounts
  alias Autolaunch.Accounts.{EnsIdentity, LinkedIdentity}
  alias Autolaunch.Actors.System

  @social_providers [:x, :github, :farcaster]

  def establish(%RegentPrivy.Session{privy_user_id: did} = verified)
      when is_binary(did) and did != "" do
    actor = %System{}

    case linked_wallet_evidence(verified) do
      {:ok, primary, addresses} ->
        with {:ok, account} <-
               Accounts.register_verified(did, primary, addresses, actor: actor),
             {:ok, account} <-
               Accounts.refresh_verified(account, primary, addresses, actor: actor),
             {:ok, conflicts} <-
               reconcile_linked_identities(account, verified.linked_socials, actor),
             :ok <- request_ens_lookup(account, actor) do
          {:ok, account, conflicts}
        end

      {:error, :missing_linked_wallet} ->
        invalidate_wallet_evidence(did, actor)
    end
  end

  def establish(_verified), do: {:error, :invalid_verified_identity}

  def current?(%{wallet_address: primary, wallet_addresses: addresses})
      when is_binary(primary) and is_list(addresses) do
    addresses != [] and primary in addresses
  end

  def current?(_account), do: false

  # Each sign-in asks Ethereum for the wallet's ENS name and picture again.
  defp request_ens_lookup(account, actor) do
    if EnsIdentity.looking_up?() do
      with {:ok, _identity} <-
             Accounts.request_ens_lookup(account.id, account.wallet_address, actor: actor),
           do: :ok
    else
      :ok
    end
  end

  defp reconcile_linked_identities(account, linked_socials, actor)
       when is_list(linked_socials) do
    with {:ok, existing} <-
           Accounts.list_linked_identities_for_account(account.id, actor: actor),
         {:ok, token_providers, conflicts} <-
           upsert_linked_socials(linked_socials, account.id, actor),
         :ok <- remove_missing_socials(existing, token_providers, account, actor) do
      {:ok, conflicts}
    end
  end

  defp reconcile_linked_identities(_account, _linked_socials, _actor),
    do: {:error, :invalid_verified_identity}

  defp upsert_linked_socials(linked_socials, human_account_id, actor) do
    Enum.reduce_while(linked_socials, {:ok, MapSet.new(), []}, fn social, state ->
      reduce_linked_social(social, state, human_account_id, actor)
    end)
  end

  defp reduce_linked_social(social, state, human_account_id, actor) do
    social
    |> linked_social_provider()
    |> reduce_linked_social_provider(social, state, human_account_id, actor)
  end

  defp reduce_linked_social_provider(
         {:ok, provider},
         social,
         {:ok, providers, _conflicts} = state,
         human_account_id,
         actor
       ) do
    if MapSet.member?(providers, provider) do
      {:cont, state}
    else
      upsert_first_linked_social(social, provider, state, human_account_id, actor)
    end
  end

  defp reduce_linked_social_provider(
         {:error, error},
         _social,
         _state,
         _human_account_id,
         _actor
       ),
       do: {:halt, {:error, error}}

  defp upsert_first_linked_social(
         social,
         provider,
         {:ok, providers, conflicts},
         human_account_id,
         actor
       ) do
    providers = MapSet.put(providers, provider)

    case upsert_linked_social(social, human_account_id, actor) do
      {:ok, ^provider} -> {:cont, {:ok, providers, conflicts}}
      {:conflict, ^provider} -> {:cont, {:ok, providers, [provider | conflicts]}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp linked_social_provider(%{provider: provider, subject: subject})
       when provider in @social_providers and is_binary(subject) and subject != "",
       do: {:ok, provider}

  defp linked_social_provider(_social), do: {:error, :invalid_verified_identity}

  # The subject still linked to the account is refreshed where it stands; when no
  # row holds it for the account, whatever another sign-in just did, it is linked.
  defp upsert_linked_social(
         %{provider: provider, subject: subject, username: _, display_name: _} = social,
         human_account_id,
         actor
       )
       when provider in @social_providers and is_binary(subject) and subject != "" do
    case refresh_linked_social(social, human_account_id, actor) do
      :ok -> {:ok, provider}
      :not_linked -> link_social(social, human_account_id, actor)
      {:error, error} -> {:error, error}
    end
  end

  defp upsert_linked_social(_social, _human_account_id, _actor),
    do: {:error, :invalid_verified_identity}

  # The account's own row for the subject takes the names Privy lists now and
  # the time of this check, leaving when it was linked alone. One statement finds
  # the row by provider, subject and account and updates it; no row matched is
  # a subject the account does not hold now.
  defp refresh_linked_social(
         %{provider: provider, subject: subject} = social,
         human_account_id,
         actor
       ) do
    LinkedIdentity
    |> Ash.Query.for_read(:for_account, %{human_account_id: human_account_id}, actor: actor)
    |> Ash.Query.filter(provider == ^provider and subject == ^subject)
    |> Accounts.refresh_linked_identity(
      %{
        username: social.username,
        display_name: social.display_name,
        verified_at: DateTime.utc_now(),
        metadata: %{}
      },
      actor: actor,
      # Anyone but the site is refused, not counted as a link that is gone.
      bulk_options: [
        strategy: :atomic,
        return_records?: true,
        return_errors?: true,
        authorize_with: :error
      ]
    )
    |> case do
      %Ash.BulkResult{status: :success, records: [_identity]} -> :ok
      %Ash.BulkResult{status: :success, records: []} -> :not_linked
      %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
    end
  end

  # A first link for the provider, or one that replaces the account's earlier
  # subject. A subject other accounts hold is linked here as well when its
  # provider's accounts are shared (X); otherwise the database refuses it.
  defp link_social(social, human_account_id, actor) do
    case Accounts.upsert_linked_identity(
           social.provider,
           social.subject,
           social.username,
           social.display_name,
           DateTime.utc_now(),
           %{},
           human_account_id,
           actor: actor
         ) do
      {:ok, _identity} -> {:ok, social.provider}
      {:error, error} -> conflict_or_error(error, social.provider)
    end
  end

  # `LinkedIdentity` `:unique_subject_per_provider` refuses a subject another
  # account holds, one a concurrent sign-in just took included, with an error on
  # the subject alone that names the unique rule: that is the conflict.
  defp conflict_or_error(%Ash.Error.Invalid{errors: errors} = error, provider) do
    if Enum.any?(errors, &subject_taken?/1), do: {:conflict, provider}, else: {:error, error}
  end

  defp conflict_or_error(error, _provider), do: {:error, error}

  defp subject_taken?(%InvalidAttribute{field: :subject, private_vars: vars}),
    do: vars[:constraint_type] == :unique

  defp subject_taken?(_error), do: false

  defp remove_missing_socials(existing, token_providers, account, actor) do
    existing
    |> Enum.filter(
      &((&1.provider in @social_providers and not MapSet.member?(token_providers, &1.provider)) or
          (&1.provider == :ens and
             not RegentChain.Address.equal?(&1.metadata["wallet"], account.wallet_address)))
    )
    |> Enum.reduce_while(:ok, fn identity, :ok ->
      case Accounts.remove_linked_identity(identity, actor: actor) do
        {:ok, _identity} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp linked_wallet_evidence(%{wallet_address: primary, wallet_addresses: addresses})
       when is_list(addresses) do
    addresses =
      addresses
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    if primary in addresses,
      do: {:ok, primary, addresses},
      else: {:error, :missing_linked_wallet}
  end

  defp linked_wallet_evidence(_verified), do: {:error, :missing_linked_wallet}

  defp invalidate_wallet_evidence(did, actor) do
    with {:ok, account} when not is_nil(account) <-
           Accounts.get_by_privy_did(did, actor: actor),
         {:ok, _account} <- Accounts.refresh_verified(account, nil, [], actor: actor) do
      {:error, :missing_linked_wallet}
    else
      {:ok, nil} -> {:error, :missing_linked_wallet}
      error -> error
    end
  end
end
