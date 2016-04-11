use Croma

defmodule PoolSup.Multi do
  @moduledoc """
  TODO
  """

  alias Supervisor, as: S
  alias GenServer, as: GS
  use GS
  alias  PoolSup.PidSet
  import PoolSup.CustomSupHelper

  @type  pool_multi     :: pid | GS.name
  @type  pool_multi_key :: term
  @type  pool_sup_args  :: [module | term | non_neg_integer | non_neg_integer]
  @type  options        :: [name: GS.name]
  @typep sup_state      :: PoolSup.CustomSupHelper.sup_state

  require Record
  Record.defrecordp :state, [
    :sup_state,
    :table_id,
    :pool_multi_key,
    :terminating_pools,
    :reserved,
    :ondemand,
  ]
  @typep state :: record(:state,
    sup_state:         term,
    table_id:          :ets.tab,
    pool_multi_key:    pool_multi_key,
    terminating_pools: PidSet.t,
    reserved:          non_neg_integer,
    ondemand:          non_neg_integer,
  )

  @termination_progress_check_interval (if Mix.env == :test, do: 10, else: 60_000)

  #
  # client API
  #
  @doc """
  TODO
  """
  defun start_link(table_id        :: :ets.tab,
                   pool_multi_key  :: pool_multi_key,
                   n_pools         :: g[non_neg_integer],
                   worker_module   :: g[module],
                   worker_init_arg :: term,
                   reserved        :: g[non_neg_integer],
                   ondemand        :: g[non_neg_integer],
                   options         :: options \\ []) :: GS.on_start do
    init_arg = {table_id, pool_multi_key, n_pools, worker_module, worker_init_arg, reserved, ondemand, options}
    GS.start_link(__MODULE__, init_arg, gen_server_opts(options))
  end

  @doc """
  TODO
  """
  defun change_configuration(name :: pools, n_pools :: nil_or_nni, reserved :: nil_or_nni, ondemand :: nil_or_nni) :: :ok when nil_or_nni: nil | non_neg_integer do
    (_   , nil, nil, nil) -> :ok
    (name, n  , r  , o  ) when is_nil_or_nni(n) and is_nil_or_nni(r) and is_nil_or_nni(o) ->
      GenServer.cast(name, {:change_configuration, n, r, o})
  end

  @doc """
  TODO
  """
  defun checkout(table_id :: :ets.tab, pool_multi_key :: pool_multi_key, timeout :: timeout \\ 5000) :: {pid, pid} do
    checkout_common(table_id, pool_multi_key, fn pool_pid ->
      {pool_pid, PoolSup.checkout(pool_pid, timeout)}
    end)
  end

  @doc """
  TODO
  """
  defun checkout_nonblocking(table_id :: :ets.tab, pool_multi_key :: pool_multi_key, timeout :: timeout \\ 5000) :: nil | {pid, pid} do
    checkout_common(table_id, pool_multi_key, fn pool_pid ->
      case PoolSup.checkout_nonblocking(pool_pid, timeout) do
        nil        -> nil
        worker_pid -> {pool_pid, worker_pid}
      end
    end)
  end

  defunp checkout_common(table_id :: :ets.tab, pool_multi_key :: pool_multi_key, f :: (pid -> r), dead_pids :: [pid] \\ []) :: r when r: nil | {pid, pid} do
    pool_pid = pick_pool(table_id, pool_multi_key, dead_pids)
    try do
      f.(pool_pid)
    catch
      :exit, {reason, _} when reason in [:noproc, :shutdown] -> checkout_common(table_id, pool_multi_key, f, [pool_pid | dead_pids])
    end
  end

  defunp pick_pool(table_id :: :ets.tab, pool_multi_key :: pool_multi_key, dead_pids) :: pid do
    pid_tuple0 = :ets.lookup_element(table_id, pool_multi_key, 2)
    pid_tuple  = if Enum.empty?(dead_pids), do: pid_tuple0, else: List.to_tuple(Tuple.to_list(pid_tuple0) -- dead_pids)
    size = tuple_size(pid_tuple)
    if size == 0, do: raise "no pool available"
    elem(pid_tuple, abs(rem(System.monotonic_time, size))) # use modulo of nano-second time to pick a pool
  end

  @doc """
  TODO
  """
  defun transaction(table_id :: :ets.tab, pool_multi_key :: pool_multi_key, f :: (pid -> a), timeout :: timeout \\ 5000) :: a when a: term do
    {pool_pid, worker_pid} = checkout(table_id, pool_multi_key, timeout)
    try do
      f.(worker_pid)
    after
      PoolSup.checkin(pool_pid, worker_pid)
    end
  end

  #
  # gen_server callbacks
  #
  def init({table_id, pool_multi_key, n_pools, worker_module, worker_init_arg, reserved, ondemand, opts}) do
    {:ok, sup_state0} = :supervisor.init(supervisor_init_arg(worker_module, worker_init_arg, opts))
    sup_state = spawn_pools(sup_state0, n_pools, reserved, ondemand)
    s = state(sup_state:         sup_state,
              table_id:          table_id,
              pool_multi_key:    pool_multi_key,
              terminating_pools: PidSet.new,
              reserved:          reserved,
              ondemand:          ondemand)
    reset_pids_record(s)
    {:ok, s}
  end

  defp supervisor_init_arg(worker_module, worker_init_arg, opts) do
    sup_name = opts[:name] || :self
    worker_spec = S.Spec.supervisor(PoolSup, [worker_module, worker_init_arg], [restart: :permanent, shutdown: :infinity])
    spec = S.Spec.supervise([worker_spec], strategy: :simple_one_for_one)
    {sup_name, PoolSup.Callback, [spec]}
  end

  defunp spawn_pools(sup_state :: sup_state, pools_to_add :: non_neg_integer, reserved :: non_neg_integer, ondemand :: non_neg_integer) :: sup_state do
    if pools_to_add == 0 do
      sup_state
    else
      {_pid, new_sup_state} = start_child(sup_state, [reserved, ondemand])
      spawn_pools(new_sup_state, pools_to_add - 1, reserved, ondemand)
    end
  end

  defunp reset_pids_record(state(sup_state:         sup_state,
                                 table_id:          table_id,
                                 pool_multi_key:    pool_multi_key,
                                 terminating_pools: terminating_pools) :: state,
                           pool_pids :: nil | [pid] \\ nil) :: true do
    pids =
      case pool_pids do
        nil -> extract_child_pids(sup_state) |> Enum.reject(&PidSet.member?(terminating_pools, &1))
        _   -> pool_pids
      end
    :ets.insert(table_id, {pool_multi_key, List.to_tuple(pids)})
  end

  defunp extract_child_pids(sup_state :: sup_state) :: [pid] do
    {:reply, r, _} = :supervisor.handle_call(:which_children, nil, sup_state)
    Enum.map(r, fn {_, pid, _, _} -> pid end)
  end

  handle_call_default_clauses

  def handle_cast({:change_configuration, n_pools, reserved1, ondemand1},
                  state(sup_state: sup_state, reserved: reserved0, ondemand: ondemand0) = s) do
    reserved = reserved1 || reserved0
    ondemand = ondemand1 || ondemand0
    s2 = state(s, reserved: reserved, ondemand: ondemand)
    pool_pids = extract_child_pids(sup_state)
    s3 = if n_pools, do: adjust_number_of_pools(s2, n_pools, pool_pids), else: s2
    change_capacity_of_pools(s3, pool_pids)
    {:noreply, s3}
  end

  defunp adjust_number_of_pools(state(sup_state:         sup_state,
                                      terminating_pools: terminating_pools,
                                      reserved:          reserved,
                                      ondemand:          ondemand) = s :: state,
                                n_pools :: non_neg_integer,
                                pool_pids :: [pid]) :: state do
    working_pools = Enum.reject(pool_pids, &PidSet.member?(terminating_pools, &1))
    len = length(working_pools)
    cond do
      len == n_pools -> s
      len <  n_pools ->
        new_sup_state = spawn_pools(sup_state, n_pools - len, reserved, ondemand)
        s2 = state(s, sup_state: new_sup_state)
        reset_pids_record(s2)
        s2
      len >  n_pools ->
        {pools_to_keep, pools_to_terminate} = Enum.shuffle(working_pools) |> Enum.split(n_pools)
        reset_pids_record(s, pools_to_keep)
        terminating_pools2 = Enum.reduce(pools_to_terminate, terminating_pools, &PidSet.put(&2, &1))
        Enum.each(pools_to_terminate, fn pid -> PoolSup.change_capacity(pid, 0, 0) end)
        arrange_next_progress_check
        state(s, terminating_pools: terminating_pools2)
    end
  end

  defunp change_capacity_of_pools(state(terminating_pools: terminating_pools, reserved: reserved, ondemand: ondemand) :: state,
                                  original_pool_pids :: [pid]) :: :ok do
    Enum.reject(original_pool_pids, &PidSet.member?(terminating_pools, &1))
    |> Enum.each(fn pool_pid ->
      PoolSup.change_capacity(pool_pid, reserved, ondemand)
    end)
  end

  defunp arrange_next_progress_check :: :ok do
    _timer_ref_not_used = Process.send_after(self, :check_progress_of_termination, @termination_progress_check_interval)
    :ok
  end

  def handle_info(:check_progress_of_termination,
                  state(sup_state: sup_state0, terminating_pools: terminating_pools) = s) do
    terminatable_pool_pids =
      PidSet.to_list(terminating_pools)
      |> Enum.filter(&(PoolSup.status(&1)[:children] == 0))
    new_terminating_pools = Enum.reduce(terminatable_pool_pids, terminating_pools, &PidSet.delete(&2, &1))
    new_sup_state =
      Enum.reduce(terminatable_pool_pids, sup_state0, fn(pool_pid, sup_state) ->
        terminate_child(pool_pid, sup_state)
      end)
    s2 = state(s, sup_state: new_sup_state, terminating_pools: new_terminating_pools)
    if !Enum.empty?(new_terminating_pools) do
      arrange_next_progress_check
    end
    {:noreply, s2}
  end
  def handle_info(msg, state(sup_state: sup_state, terminating_pools: terminating_pools) = s) do
    case msg do
      {:EXIT, pid, _reason} ->
        if PidSet.member?(terminating_pools, pid) do
          # We know that the `pid` already died and we can use `terminate_child` to clean up `sup_state`
          new_sup_state = terminate_child(pid, sup_state)
          new_terminating_pools = PidSet.delete(terminating_pools, pid)
          {:noreply, state(s, sup_state: new_sup_state, terminating_pools: new_terminating_pools)}
        else
          s2 = delegate_info_message_to_supervisor_callback(msg, s)
          reset_pids_record(s2)
          {:noreply, s2}
        end
      _ -> {:noreply, delegate_info_message_to_supervisor_callback(msg, s)}
    end
  end

  defunp delegate_info_message_to_supervisor_callback(msg :: term, state(sup_state: sup_state) = s :: state) :: state do
    {:noreply, new_sup_state} = :supervisor.handle_info(msg, sup_state)
    state(s, sup_state: new_sup_state)
  end

  code_change_default_clause

  defdelegate [terminate(reason, state), format_status(opt, list)], to: PoolSup.CustomSupHelper
end
