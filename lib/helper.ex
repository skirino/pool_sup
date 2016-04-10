use Croma

defmodule PoolSup.CustomSupHelper do
  @moduledoc false

  @typep sup_state    :: term

  defmacro is_nil_or_nni(v) do
    quote do
      is_nil(unquote(v)) or is_integer(unquote(v)) and unquote(v) >= 0
    end
  end

  defun gen_server_opts(opts :: Keyword.t(any)) :: [name: GenServer.name] do
    Enum.filter(opts, &match?({:name, _}, &1))
  end

  # We need to define `format_status` to pretend as if it's an ordinary supervisor when `sys:get_status/1` is called
  # (assuming that `sup_state` is the first element in record)
  def format_status(:terminate, [_pdict, state]), do: state
  def format_status(:normal   , [_pdict, state]), do: [{:data, [{'State', elem(state, 1)}]}]
end
