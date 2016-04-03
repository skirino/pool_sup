defmodule PoolSup.Worker do
  @moduledoc """
  Behaviour definition of worker processes to be managed by `PoolSup`.
  """

  @callback start_link(term) :: GenServer.on_start
end
