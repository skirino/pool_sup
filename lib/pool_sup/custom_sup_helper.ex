use Croma

defmodule PoolSup.CustomSupHelper do
  @moduledoc false

  @type sup_state :: term
  @type init_option ::
          {:max_restarts , non_neg_integer}
          | {:max_seconds, pos_integer    }

  #
  # common gen_server callbacks
  #
  defmacro handle_call_default_clauses() do
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

  defmacro code_change_default_clause() do
    quote do
      def code_change(old_vsn, state(sup_state: sup_state) = s, extra) do
        case :supervisor.code_change(old_vsn, sup_state, extra) do
          {:ok, new_sup_state} -> {:ok, state(s, sup_state: new_sup_state)}
          {:error, reason}     -> {:error, reason}
        end
      end
    end
  end

  def terminate(reason, state) do
    :supervisor.terminate(reason, elem(state, 1))
  end

  # We need to define `format_status` to pretend as if it's an ordinary supervisor when `sys:get_status/1` is called
  # (assuming that `sup_state` is the first element in record)
  def format_status(:terminate, [_pdict, state]), do: state
  def format_status(:normal   , [_pdict, state]), do: [{:data, [{'State', elem(state, 1)}]}]

  #
  # helpers
  #
  defmacro is_nil_or_nni(v) do
    quote do
      is_nil(unquote(v)) or is_integer(unquote(v)) and unquote(v) >= 0
    end
  end

  defun gen_server_opts(opts :: Keyword.t(any)) :: [name: GenServer.name] do
    Enum.filter(opts, &match?({:name, _}, &1))
  end

  defun make_sup_spec(worker_spec :: [Supervisor.child_spec], opts :: [init_option] \\ []) :: {:ok, tuple} do
    intensity = Keyword.get(opts, :max_restarts, 3) # Defaults to values used by Elixir's Supervisor
    period    = Keyword.get(opts, :max_seconds , 5)
    flags     = %{strategy: :simple_one_for_one, intensity: intensity, period: period} # Convert to the format of `:erlang.sup_flags`
    {:ok, {flags, worker_spec}}
  end

  defun start_child(sup_state :: sup_state, extra :: [term] \\ []) :: {pid, sup_state} do
    {:reply, {:ok, pid}, new_sup_state} = :supervisor.handle_call({:start_child, extra}, nil, sup_state)
    {pid, new_sup_state}
  end

  defun terminate_child(pid :: pid, sup_state :: sup_state) :: sup_state do
    {:reply, :ok, new_sup_state} = :supervisor.handle_call({:terminate_child, pid}, nil, sup_state)
    new_sup_state
  end

  defmacro delegate_info_message_to_supervisor_callback(msg, s) do
    quote bind_quoted: [msg: msg, s: s] do
      state(sup_state: sup_state) = s
      {:noreply, new_sup_state} = :supervisor.handle_info(msg, sup_state)
      state(s, sup_state: new_sup_state)
    end
  end
end
