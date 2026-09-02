defmodule Autolaunch.Accounts do
  use Ash.Domain

  resources do
    resource Autolaunch.Accounts.HumanAccount do
      define :get_by_privy_did,
        action: :by_privy_did,
        args: [:privy_did],
        not_found_error?: false

      define :get_human_account, action: :read_self, args: [:id]

      define :get_public_profile_source,
        action: :public_profile_source,
        args: [:id],
        not_found_error?: false

      define :register_verified,
        action: :register_verified,
        args: [:privy_did, :wallet_address, :wallet_addresses]

      define :refresh_verified,
        action: :refresh_verified,
        args: [:wallet_address, :wallet_addresses]

      define :set_display_name, action: :set_display_name
      define :set_avatar, action: :set_avatar
    end

    resource Autolaunch.Accounts.SessionAuthority

    resource Autolaunch.Accounts.LinkedIdentity do
      define :upsert_linked_identity,
        action: :upsert_verified,
        args: [
          :provider,
          :subject,
          :username,
          :display_name,
          :verified_at,
          :metadata,
          :human_account_id
        ]

      define :list_my_linked_identities, action: :read_mine

      define :list_linked_identities_for_account,
        action: :for_account,
        args: [:human_account_id]

      define :get_linked_identity_by_subject,
        action: :by_provider_subject,
        args: [:provider, :subject],
        not_found_error?: false

      define :remove_linked_identity, action: :remove_verified
    end

    resource Autolaunch.Accounts.XConnection do
      define :begin_x_connection_attempt, action: :begin_attempt
      define :record_x_connection_intent, action: :record_intent
      define :list_my_x_connections, action: :mine

      define :get_my_x_connection,
        action: :mine_by_role,
        args: [:role],
        not_found_error?: false

      define :get_my_x_connection_for_update,
        action: :mine_by_role_for_update,
        args: [:role],
        not_found_error?: false

      define :list_public_x_connections,
        action: :public_for_humans,
        args: [:human_account_ids]

      define :replace_x_connection_attempt, action: :replace_attempt
      define :complete_x_connection_attempt, action: :complete_attempt
      define :clear_x_connection_attempt, action: :clear_attempt

      define :cancel_x_connection_attempt,
        action: :cancel_attempt,
        args: [:intent_sequence, :intent_generation]

      define :disconnect_x_connection,
        action: :disconnect,
        args: [:intent_sequence, :intent_generation]
    end
  end
end
