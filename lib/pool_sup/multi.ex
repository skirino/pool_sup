use Croma

defmodule PoolSup.Multi do
  @moduledoc """
  Defines a supervisor that is specialized to manage multiple `PoolSup` processes.

  For high-throughput use cases, centralized process pool such as `PoolSup`
  may become a bottleneck as all tasks must checkout from a single pool manager process.
  This module is for these situations: to manage multiple `PoolSup`s and
  load-balance checkout requests to multiple pool manager processes.

  In summary,

  - Process defined by `PoolSup.Multi` behaves as a `:simple_one_for_one` supervisor.
  - Children of `PoolSup.Multi` are `PoolSup` processes and they have identical configurations (worker module, capacity, etc.).
  - `checkout/3`, `checkout_nonblocking/3` and `transaction/4` which randomly picks a pool
    in a `PoolSup.Multi` (with the help of ETS) are provided.
  - Number of pools and capacity of each pool are dynamically configurable.

  ## Example

  Suppose we have the following worker module:

      iex(1)> defmodule MyWorker do
      ...(1)>   @behaviour PoolSup.Worker
      ...(1)>   use GenServer
      ...(1)>   def start_link(arg) do
      ...(1)>     GenServer.start_link(__MODULE__, arg)
      ...(1)>   end
      ...(1)>   # definitions of gen_server callbacks...
      ...(1)> end

  To use `PoolSup.Multi` it's necessary to setup an ETS table.

      iex(2)> table_id = :ets.new(:arbitrary_table_name, [:set, :public, {:read_concurrency, true}])

  Note that the `PoolSup.Multi` process must be able to write to the table.
  The following creates a `PoolSup.Multi` process that has 3 `PoolSup`s each of which manages 5 reserved and 2 ondemand workers.

      iex(3)> {:ok, pool_multi_pid} = PoolSup.Multi.start_link(table_id, "arbitrary_key", 3, MyWorker, {:worker, :arg}, 5, 2)

  Now we can checkout a worker pid from the set of pools:

      iex(4)> {pool_pid, worker_pid} = PoolSup.Multi.checkout(table_id, "arbitrary_key")
      iex(5)> do_something(worker_pid)
      iex(6)> PoolSup.checkin(pool_pid, worker_pid)
  """

  alias Supervisor, as: S
  alias GenServer, as: GS
  use GS
  alias PoolSup.PidSet
  alias PoolSup.CustomSupHelper, as: H
  require H

  @type  pool_multi     :: pid | GS.name
  @type  pool_multi_key :: term
  @type  pool_sup_args  :: [module | term | non_neg_integer | non_neg_integer]
  @type  option         :: {:name, GS.name} | {:checkout_max_duration, pos_integer}
  @typep sup_state      :: H.sup_state

  require Record
  Record.defrecordp :state, [
    :sup_state,
    :table_id,
    :pool_multi_key,
    :terminating_pools,
    :reserved,
    :ondemand,
    :checkout_max_duration,
  ]
  @typep state :: record(:state,
    sup_state:             term,
    table_id:              :ets.tab,
    pool_multi_key:        pool_multi_key,
    terminating_pools:     PidSet.t,
    reserved:              non_neg_integer,
    ondemand:              non_neg_integer,
    checkout_max_duration: nil | pos_integer)

  @termination_progress_check_interval (if Mix.env == :test, do: 10, else: 60_000)

  #
  # client API
  #
  @doc """
  Starts a `PoolSup.Multi` process linked to the calling process.

  ## Arguments

  - `table_id`: ID of the ETS table to use.
  - `pool_multi_key`: Key to identify the record in the ETS table.
    Note that `PoolSup.Multi` keeps track of the `PoolSup`s within a single ETS record.
    Thus multiple instances of `PoolSup.Multi` can share the same ETS table (as long as they use unique keys).
  - `n_pools`: Number of pools.
  - `worker_module`: Callback module of `PoolSup.Worker`.
  - `worker_init_arg`: Value passed to `worker_module.start_link/1`.
  - `reserved`: Number of reserved workers in each `PoolSup`.
  - `ondemand`: Number of ondemand workers in each `PoolSup`.
  - `options`: Keyword list of the following options:
      - `:name`: Used for name registration of `PoolSup.Multi` process.
      - `:checkout_max_duration`: An option passed to child pools. See `PoolSup.start_link/5` for detail.
  """
  defun start_link(table_id        :: :ets.tab,
                   pool_multi_key  :: pool_multi_key,
                   n_pools         :: g[non_neg_integer],
                   worker_module   :: g[module],
                   worker_init_arg :: term,
                   reserved        :: g[non_neg_integer],
                   ondemand        :: g[non_neg_integer],
                   options         :: g[[option]] \\ []) :: GS.on_start do
    init_arg = {table_id, pool_multi_key, n_pools, worker_module, worker_init_arg, reserved, ondemand, options}
    GS.start_link(__MODULE__, init_arg, H.gen_server_opts(options))
  end

  @doc """
  Checks out a worker pid that is currently not used.

  Internally this function looks-up the specified ETS record,
  randomly chooses one of the pools and checks-out a worker in the pool.

  Note that this function returns a pair of `pid`s: `{pool_pid, worker_pid}`.
  The returned `pool_pid` must be used when returning the worker to the pool: `PoolSup.checkin(pool_pid, worker_pid)`.
  """
  defun checkout(table_id :: :ets.tab, pool_multi_key :: pool_multi_key, timeout :: timeout \\ 5000) :: {pid, pid} do
    checkout_common(table_id, pool_multi_key, fn pool_pid ->
      {pool_pid, PoolSup.checkout(pool_pid, timeout)}
    end)
  end

  @doc """
  Checks out a worker pid in a nonblocking manner, i.e. if no available worker found in the randomly chosen pool this returns `nil`.
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
    pid_tuple  =
      case dead_pids do
        [] -> pid_tuple0
        _  -> List.to_tuple(Tuple.to_list(pid_tuple0) -- dead_pids)
      end
    case tuple_size(pid_tuple) do
      0    -> raise "no pool available"
      1    -> elem(pid_tuple, 0)
      size -> elem(pid_tuple, :erlang.phash2(self(), size))
    end
  end

  @doc """
  Picks a pool from the specified ETS record, checks out a worker pid, creates a link to the worker, executes the given function using the pid,
  and finally checks-in and unlink.

  The `timeout` parameter is used only in the checkout step; time elapsed during other steps are not counted.
  """
  defun transaction(table_id :: :ets.tab, pool_multi_key :: pool_multi_key, f :: (pid -> a), timeout :: timeout \\ 5000) :: a when a: term do
    {pool_pid, worker_pid} = checkout(table_id, pool_multi_key, timeout)
    try do
      Process.link(worker_pid)
      f.(worker_pid)
    after
      PoolSup.checkin(pool_pid, worker_pid)
      Process.unlink(worker_pid)
    end
  end

  @doc """
  Changes configuration of an existing `PoolSup.Multi` process.

  `new_n_pools`, `new_reserved` and/or `new_ondemand` parameters can be `nil`; in that case the original value is kept unchanged.

  ## Changing number of pools

  - When `new_n_pools` is larger than the current number of working pools, `PoolSup.Multi` spawns new pools immediately.
  - When `new_n_pools` is smaller than the current number of working pools, `PoolSup.Multi` process
      - randomly chooses pools to terminate and mark them "not working",
      - exclude those pools from the ETS record,
      - resets their `reserved` and `ondemand` as `0` so that new checkouts will never succeed,
      - starts to periodically poll the status of "not working" pools, and
      - terminate a pool when it becomes ready to terminate (i.e. no worker process is used).

  ## Changing `reserved` and/or `ondemand` of each pool

  - The given values of `reserved`, `ondemand` are notified to all the working pools.
    See `PoolSup.change_capacity/3` for the behaviour of each pool.
  """
  defun change_configuration(pid_or_name  :: pool_multi,
                             new_n_pools  :: nil_or_nni,
                             new_reserved :: nil_or_nni,
                             new_ondemand :: nil_or_nni) :: :ok when nil_or_nni: nil | non_neg_integer do
    (_          , nil, nil, nil) -> :ok
    (pid_or_name, n  , r  , o  ) when H.is_nil_or_nni(n) and H.is_nil_or_nni(r) and H.is_nil_or_nni(o) ->
      GenServer.cast(pid_or_name, {:change_configuration, n, r, o})
  end

  @doc """
  Changes `:checkout_max_duration` option of child pools.

  See `PoolSup.start_link/5` for detailed explanation of `:checkout_max_duration` option.
  The change will be broadcasted to all existing pools.
  Also all pools that start afterward will use the new value of `:checkout_max_duration`.
  """
  defun change_checkout_max_duration(pid_or_name :: pool_multi, new_duration :: nil | pos_integer) :: :ok do
    case new_duration do
      nil                            -> :ok
      d when is_integer(d) and d > 0 -> :ok
    end
    GenServer.cast(pid_or_name, {:change_checkout_max_duration, new_duration})
  end

  #
  # gen_server callbacks
  #
  def init({table_id, pool_multi_key, n_pools, worker_module, worker_init_arg, reserved, ondemand, opts}) do
    {:ok, sup_state0} = :supervisor.init(supervisor_init_arg(worker_module, worker_init_arg, opts))
    dur =
      case opts[:checkout_max_duration] do
        nil -> nil
        d when is_integer(d) and d > 0 -> d
      end
    sup_state = spawn_pools(sup_state0, n_pools, reserved, ondemand, dur)
    s = state(sup_state:             sup_state,
              table_id:              table_id,
              pool_multi_key:        pool_multi_key,
              terminating_pools:     PidSet.new(),
              reserved:              reserved,
              ondemand:              ondemand,
              checkout_max_duration: dur)
    reset_pids_record(s)
    {:ok, s}
  end

  defp supervisor_init_arg(worker_module, worker_init_arg, opts) do
    sup_name = opts[:name] || :self
    worker_spec = S.Spec.supervisor(PoolSup, [worker_module, worker_init_arg], [restart: :permanent, shutdown: :infinity])
    spec = S.Spec.supervise([worker_spec], strategy: :simple_one_for_one)
    {sup_name, PoolSup.Callback, [spec]}
  end

  defunp spawn_pools(sup_state    :: sup_state,
                     pools_to_add :: non_neg_integer,
                     reserved     :: non_neg_integer,
                     ondemand     :: non_neg_integer,
                     max_duration :: nil | pos_integer) :: sup_state do
    if pools_to_add == 0 do
      sup_state
    else
      {_pid, new_sup_state} = H.start_child(sup_state, [reserved, ondemand, [checkout_max_duration: max_duration]])
      spawn_pools(new_sup_state, pools_to_add - 1, reserved, ondemand, max_duration)
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

  H.handle_call_default_clauses

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
  def handle_cast({:change_checkout_max_duration, dur}, state(sup_state: sup_state) = s) do
    extract_child_pids(sup_state)
    |> Enum.each(fn pool ->
      PoolSup.change_checkout_max_duration(pool, dur)
    end)
    {:noreply, state(s, checkout_max_duration: dur)}
  end

  defunp adjust_number_of_pools(state(sup_state:             sup_state,
                                      terminating_pools:     terminating_pools,
                                      reserved:              reserved,
                                      ondemand:              ondemand,
                                      checkout_max_duration: dur) = s :: state,
                                n_pools :: non_neg_integer,
                                pool_pids :: [pid]) :: state do
    working_pools = Enum.reject(pool_pids, &PidSet.member?(terminating_pools, &1))
    len = length(working_pools)
    cond do
      len == n_pools -> s
      len <  n_pools ->
        new_sup_state = spawn_pools(sup_state, n_pools - len, reserved, ondemand, dur)
        s2 = state(s, sup_state: new_sup_state)
        reset_pids_record(s2)
        s2
      len >  n_pools ->
        {pools_to_keep, pools_to_terminate} = Enum.shuffle(working_pools) |> Enum.split(n_pools)
        reset_pids_record(s, pools_to_keep)
        terminating_pools2 = Enum.reduce(pools_to_terminate, terminating_pools, &PidSet.put(&2, &1))
        Enum.each(pools_to_terminate, fn pid -> PoolSup.change_capacity(pid, 0, 0) end)
        arrange_next_progress_check()
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
    _timer_ref_not_used = Process.send_after(self(), :check_progress_of_termination, @termination_progress_check_interval)
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
        H.terminate_child(pool_pid, sup_state)
      end)
    s2 = state(s, sup_state: new_sup_state, terminating_pools: new_terminating_pools)
    if !Enum.empty?(new_terminating_pools) do
      arrange_next_progress_check()
    end
    {:noreply, s2}
  end
  def handle_info(msg, state(sup_state: sup_state, terminating_pools: terminating_pools) = s) do
    case msg do
      {:EXIT, pid, _reason} ->
        if PidSet.member?(terminating_pools, pid) do
          # We know that the `pid` already died and we can use `terminate_child` to clean up `sup_state`
          new_sup_state = H.terminate_child(pid, sup_state)
          new_terminating_pools = PidSet.delete(terminating_pools, pid)
          {:noreply, state(s, sup_state: new_sup_state, terminating_pools: new_terminating_pools)}
        else
          s2 = H.delegate_info_message_to_supervisor_callback(msg, s)
          reset_pids_record(s2)
          {:noreply, s2}
        end
      _ -> {:noreply, H.delegate_info_message_to_supervisor_callback(msg, s)}
    end
  end

  def terminate(reason, state(table_id: table_id, pool_multi_key: pool_multi_key) = s) do
    :ets.delete(table_id, pool_multi_key)
    H.terminate(reason, s)
  end

  H.code_change_default_clause

  defdelegate terminate(reason, state), to: H
  defdelegate format_status(opt, list), to: H
end
