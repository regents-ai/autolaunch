defmodule Autolaunch.Revenue.ShareHistory do
  @moduledoc false

  alias Autolaunch.Revenue.Core

  defdelegate subject_scope(subject_id, current_human \\ nil), to: Core
end
