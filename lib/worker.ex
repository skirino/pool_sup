defmodule PoolSup.Worker do
  @moduledoc """
  Behaviour definition of worker processes to be managed by `PoolSup`.

  To implement `PoolSup.Worker` behaviour it's enough to implement just one function `start_link/1`.
  The `start_link/1` callback function is invoked by `PoolSup` to spawn a new process.
  The argument passed to worker's `start_link/1` is the second argument of `PoolSup.start_link/4`.
  """

  @callback start_link(term) :: GenServer.on_start
end
