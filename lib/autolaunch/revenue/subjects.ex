defmodule Autolaunch.Revenue.Subjects do
  @moduledoc false

  alias Autolaunch.Revenue.Core

  defdelegate get_subject(subject_id, current_human \\ nil), to: Core
  defdelegate subject_scope(subject_id, current_human \\ nil), to: Core
  defdelegate subject_state(subject_id, current_human \\ nil), to: Core

  defdelegate subject_portfolio_state(subject_id, wallet_addresses, current_human \\ nil),
    to: Core
end
