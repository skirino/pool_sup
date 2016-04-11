defmodule PoolSup.Callback do
  @moduledoc false
  # The sole purpose of this module is to suppress dialyzer warning;
  # using `Supervisor.Default` results in a warning due to (seemingly) incorrect typespec of
  # `supervisor:init/1` (which is an implementation of `gen_server:init/1` callback, not callback of supervisor behaviour).
  @behaviour :supervisor
  def init([arg]), do: arg
end
