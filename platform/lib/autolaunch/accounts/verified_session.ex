defmodule Autolaunch.Accounts.VerifiedSession do
  @moduledoc "Exchanges verified Privy evidence for the canonical human account."

  alias Autolaunch.Accounts
  alias Autolaunch.Actors.System

  @social_providers [:x, :github, :farcaster]

  def establish(%Autolaunch.VerifiedPrivyIdentity{privy_user_id: did} = verified)
      when is_binary(did) and did != "" do
    actor = %System{}

    case linked_wallet_evidence(verified) do
      {:ok, primary, addresses} ->
        with {:ok, account} <-
               Accounts.register_verified(did, primary, addresses, actor: actor),
             {:ok, account} <-
               Accounts.refresh_verified(account, primary, addresses, actor: actor),
             {:ok, conflicts} <-
               reconcile_linked_identities(account, verified.linked_socials, actor) do
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

  defp reconcile_linked_identities(account, linked_socials, actor)
       when is_list(linked_socials) do
    with {:ok, existing} <-
           Accounts.list_linked_identities_for_account(account.id, actor: actor),
         {:ok, token_providers, conflicts} <-
           upsert_linked_socials(linked_socials, account.id, actor),
         :ok <- remove_missing_socials(existing, token_providers, actor) do
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

  defp upsert_linked_social(
         %{
           provider: provider,
           subject: subject,
           username: username,
           display_name: display_name
         },
         human_account_id,
         actor
       )
       when provider in @social_providers and is_binary(subject) and subject != "" do
    with {:ok, current} <-
           Accounts.get_linked_identity_by_subject(provider, subject, actor: actor),
         :ok <- subject_available(current, human_account_id),
         {:ok, _identity} <-
           Accounts.upsert_linked_identity(
             provider,
             subject,
             username,
             display_name,
             DateTime.utc_now(),
             %{},
             human_account_id,
             actor: actor
           ) do
      {:ok, provider}
    else
      {:error, :already_linked} -> {:conflict, provider}
      {:error, error} -> resolve_upsert_error(error, provider, subject, human_account_id, actor)
    end
  end

  defp upsert_linked_social(_social, _human_account_id, _actor),
    do: {:error, :invalid_verified_identity}

  defp subject_available(nil, _human_account_id), do: :ok
  defp subject_available(%{human_account_id: id}, id), do: :ok
  defp subject_available(_identity, _human_account_id), do: {:error, :already_linked}

  defp resolve_upsert_error(error, provider, subject, human_account_id, actor) do
    case Accounts.get_linked_identity_by_subject(provider, subject, actor: actor) do
      {:ok, %{human_account_id: id}} when id != human_account_id -> {:conflict, provider}
      _result -> {:error, error}
    end
  end

  defp remove_missing_socials(existing, token_providers, actor) do
    existing
    |> Enum.filter(
      &(&1.provider in @social_providers and
          not MapSet.member?(token_providers, &1.provider))
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

    case addresses do
      [] ->
        {:error, :missing_linked_wallet}

      addresses ->
        primary = if primary in addresses, do: primary, else: hd(addresses)
        {:ok, primary, addresses}
    end
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
