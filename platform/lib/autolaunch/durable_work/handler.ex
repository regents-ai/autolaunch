defmodule Autolaunch.DurableWork.Handler do
  @moduledoc """
  The deliberately small callback boundary used by `Autolaunch.DurableWork.Runner`.

  A handler owns the meaning and persistence of its context and items. `poll/2`
  must return no more than the capacity supplied by the runner; `handle/2` owns
  everything that happens for a returned item. The runner treats the value from
  `handle/2` as opaque and does not own or interpret it.
  """

  @type context :: term()
  @type item :: term()

  @callback poll(context(), capacity :: non_neg_integer()) :: [item()]
  @callback handle(context(), item()) :: term()
end
