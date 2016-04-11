use Croma

defmodule PoolSup.CustomSupHelper do
  @moduledoc false

  @typep sup_state :: term

  defmacro is_nil_or_nni(v) do
    quote do
      is_nil(unquote(v)) or is_integer(unquote(v)) and unquote(v) >= 0
    end
  end

  defmacro handle_call_default_clauses do
    quote do
      # we don't support start_child/terminate_child operation; interrupt those messages here
      def handle_call({:start_child, _}, _from, s) do
        {:reply, {:error, :pool_sup}, s}
      end
      def handle_call({:terminate_child, _}, _from, s) do
        {:reply, {:error, :simple_one_for_one}, s} # returns `:simple_one_for_one` to obey type contract of `Supervisor.terminate_child/2`
      end
      def handle_call(msg, from, state(sup_state: sup_state) = s) do
        {:reply, reply, new_sup_state} = :supervisor.handle_call(msg, from, sup_state)
        {:reply, reply, state(s, sup_state: new_sup_state)}
      end
    end
  end

  defun gen_server_opts(opts :: Keyword.t(any)) :: [name: GenServer.name] do
    Enum.filter(opts, &match?({:name, _}, &1))
  end

  defun start_child(sup_state :: sup_state, extra :: [term] \\ []) :: {pid, sup_state} do
    {:reply, {:ok, pid}, new_sup_state} = :supervisor.handle_call({:start_child, extra}, nil, sup_state)
    {pid, new_sup_state}
  end

  # We need to define `format_status` to pretend as if it's an ordinary supervisor when `sys:get_status/1` is called
  # (assuming that `sup_state` is the first element in record)
  def format_status(:terminate, [_pdict, state]), do: state
  def format_status(:normal   , [_pdict, state]), do: [{:data, [{'State', elem(state, 1)}]}]
end
