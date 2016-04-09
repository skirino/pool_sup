use Croma

defmodule PoolSup do
  @moduledoc """
  This module defines a supervisor process that is specialized to manage pool of workers.

  ## Features

  - Process defined by this module behaves as a `:simple_one_for_one` supervisor.
  - Worker processes are spawned using a callback module that implements `PoolSup.Worker` behaviour.
  - `PoolSup` process manages which worker processes are in use and which are not.
  - `PoolSup` automatically restart crashed workers.
  - Functions to request pid of an available worker process: `checkout/2`, `checkout_nonblocking/2`.
  - Run-time configuration of pool size: `change_capacity/2`.

  ## Example

  Suppose we have a module that implements both `GenServer` and `PoolSup.Worker` behaviours
  (`PoolSup.Worker` behaviour requires only 1 callback to implement, `start_link/1`).

      iex(1)> defmodule MyWorker do
      ...(1)>   @behaviour PoolSup.Worker
      ...(1)>   use GenServer
      ...(1)>   def start_link(arg) do
      ...(1)>     GenServer.start_link(__MODULE__, arg)
      ...(1)>   end
      ...(1)>   # definitions of gen_server callbacks...
      ...(1)> end

  When we want to have 3 worker processes that run `MyWorker` server:

      iex(2)> {:ok, pool_sup_pid} = PoolSup.start_link(MyWorker, {:worker, :arg}, 3, 0, [name: :my_pool])

  Each worker process is started using `MyWorker.start_link({:worker, :arg})`.
  Then we can get a pid of a child currently not in use:

      iex(3)> child_pid = PoolSup.checkout(:my_pool)
      iex(4)> do_something(child_pid)
      iex(5)> PoolSup.checkin(:my_pool, child_pid)

  Don't forget to return the `child_pid` when finished; for simple use cases `PoolSup.transaction/3` comes in handy.

  ## Reserved and on-demand worker processes

  `PoolSup` defines the following two parameters to control capacity of a pool:

  - `reserved` (3rd argument of `start_link/5`): Number of workers to keep alive.
  - `ondemand` (4th argument of `start_link/5`): Maximum number of workers that are spawned on-demand.

  In short:

      {:ok, pool_sup_pid} = PoolSup.start_link(MyWorker, {:worker, :arg}, 2, 1)
      w1  = PoolSup.checkout_nonblocking(pool_sup_pid) # => pre-spawned worker pid
      w2  = PoolSup.checkout_nonblocking(pool_sup_pid) # => pre-spawned worker pid
      w3  = PoolSup.checkout_nonblocking(pool_sup_pid) # => newly-spawned worker pid
      nil = PoolSup.checkout_nonblocking(pool_sup_pid)
      PoolSup.checkin(pool_sup_pid, w1)                # `w1` is terminated
      PoolSup.checkin(pool_sup_pid, w2)                # `w2` is kept alive
      PoolSup.checkin(pool_sup_pid, w3)                # `w3` is kept alive

  ## Usage within supervision tree

  The following code snippet spawns a supervisor that has `PoolSup` process as one of its children:

      chilldren = [
        ...
        Supervisor.Spec.supervisor(PoolSup, [MyWorker, {:worker, :arg}, 5, 3]),
        ...
      ]
      Supervisor.start_link(children, [strategy: :one_for_one])

  The `PoolSup` process initially has 5 workers and can temporarily have upto 8.
  All workers are started by `MyWorker.start_link({:worker, :arg})`.

  You can of course define a wrapper function of `PoolSup.start_link/4` and use it in your supervisor spec.
  """

  alias Supervisor, as: S
  alias GenServer, as: GS
  use GS

  defmodule Callback do
    @moduledoc false
    # The sole purpose of this module is to suppress dialyzer warning;
    # using `Supervisor.Default` results in a warning due to (seemingly) incorrect typespec of
    # `supervisor:init/1` (which is an implementation of `gen_server:init/1` callback, not callback of supervisor behaviour).
    @behaviour :supervisor
    def init([arg]), do: arg
  end

  defmodule PidSet do
    @moduledoc false
    @type t :: %{pid => true}
    defun new                           :: t      , do: %{}
    defun member?(set :: t, pid :: pid) :: boolean, do: Map.has_key?(set, pid)
    defun put(set :: t, pid :: pid)     :: t      , do: Map.put(set, pid, true)
    defun delete(set :: t, pid :: pid)  :: t      , do: Map.delete(set, pid)
  end

  @type  pool         :: pid | GS.name
  @type  options      :: [name: GS.name]
  @typep client       :: {pid, reference}
  @typep client_queue :: :queue.queue(client)
  @typep sup_state    :: term

  require Record
  Record.defrecordp :state, [
    :reserved,
    :ondemand,
    :all,
    :working,
    :available,
    :waiting,
    :sup_state,
  ]
  @typep state :: record(:state,
    reserved:  non_neg_integer,
    ondemand:  non_neg_integer,
    all:       PidSet.t,
    working:   PidSet.t,
    available: [pid],
    waiting:   client_queue,
    sup_state: sup_state,
  )

  #
  # external API
  #
  @doc """
  Starts a `PoolSup` process linked to the calling process.

  ## Arguments

  - `worker_module` is the callback module of `PoolSup.Worker`.
  - `worker_init_arg` is the value passed to `worker_module.start_link/1` callback function.
  - `reserved` is the number of workers this `PoolSup` process holds.
  - `ondemand` is the maximum number of workers that are spawned on checkouts when all reserved processes are in use.
  - Currently only `:name` option for name registration is supported.
  """
  defun start_link(worker_module   :: g[module],
                   worker_init_arg :: term,
                   reserved        :: g[non_neg_integer],
                   ondemand        :: g[non_neg_integer],
                   options         :: options \\ []) :: GS.on_start do
    GS.start_link(__MODULE__, {worker_module, worker_init_arg, reserved, ondemand, options}, gen_server_opts(options))
  end

  defunp gen_server_opts(opts :: options) :: [name: GS.name] do
    Enum.filter(opts, &match?({:name, _}, &1))
  end

  @doc """
  Checks out a worker pid that is currently not used.

  If no available worker process exists, the caller is blocked until either
  - any process becomes available, or
  - timeout is reached.
  """
  defun checkout(pool :: pool, timeout :: timeout \\ 5000) :: pid do
    try do
      GenServer.call(pool, :checkout, timeout)
    catch
      :exit, {:timeout, _} = reason ->
        GenServer.cast(pool, {:cancel_waiting, self})
        :erlang.raise(:exit, reason, :erlang.get_stacktrace)
    end
  end

  @doc """
  Checks out a worker pid in a nonblocking manner, i.e. if no available worker found this returns `nil`.
  """
  defun checkout_nonblocking(pool :: pool, timeout :: timeout \\ 5000) :: nil | pid do
    GenServer.call(pool, :checkout_nonblocking, timeout)
  end

  @doc """
  Checks in an in-use worker pid and make it available to others.
  """
  defun checkin(pool :: pool, pid :: g[pid]) :: :ok do
    GenServer.cast(pool, {:checkin, pid})
  end

  @doc """
  Checks out a worker pid, executes the given function using the pid, and then checks in the pid.

  The `timeout` parameter is used only in the checkout step; time elapsed during other steps are not counted.
  """
  defun transaction(pool :: pool, f :: (pid -> a), timeout :: timeout \\ 5000) :: a when a: term do
    pid = checkout(pool, timeout)
    try do
      f.(pid)
    after
      checkin(pool, pid)
    end
  end

  @doc """
  Query current status of a pool.
  """
  defun status(pool :: pool) :: %{reserved: nni, ondemand: nni, children: nni, available: nni, working: nni} when nni: non_neg_integer do
    GenServer.call(pool, :status)
  end

  @doc """
  Changes capacity (number of worker processes) of a pool.

  `new_reserved` and/or `new_ondemand` parameters can be `nil`; in that case the original value is kept unchanged
  (i.e. `PoolSup.change_capacity(pool, 10, nil)` replaces only `reserved` value of `pool`).

  On receipt of `change_capacity` message, the pool adjusts number of children according to the new configuration as follows:

  - If current number of workers are less than `reserved`, spawn new workers to ensure `reserved` workers are available.
    Note that, as is the same throughout the OTP framework, spawning processes under a supervisor is synchronous operation.
    Therefore increasing `reserved` too many at once may make the pool unresponsive for a while.
  - When increasing total capacity (`reserved + ondemand`) and if any client process is being checking-out in a blocking manner,
    then the newly-spawned process is returned to the client.
  - When decreasing capacity, the pool tries to shutdown extra workers that are not in use.
    Processes currently in use are never interrupted.
    If number of in-use workers is more than the desired capacity, terminating further is delayed until any worker process is checked in.
  """
  defun change_capacity(pool :: pool, new_reserved :: nil | non_neg_integer, new_ondemand :: nil | non_neg_integer) :: :ok do
    (_pool, nil, nil) -> :ok
    (pool , r  , o  ) when (is_nil(r) or is_integer(r) and r >= 0) and (is_nil(o) or is_integer(o) and o >= 0) ->
      GenServer.cast(pool, {:change_capacity, r, o})
  end

  #
  # gen_server callbacks
  #
  def init({mod, init_arg, reserved, ondemand, opts}) do
    {:ok, sup_state} = :supervisor.init(supervisor_init_arg(mod, init_arg, opts))
    s = state(reserved: reserved, ondemand: ondemand, all: PidSet.new, working: PidSet.new, available: [], waiting: :queue.new, sup_state: sup_state)
    {:ok, restock_children_upto_reserved(s)}
  end

  defp supervisor_init_arg(mod, init_arg, opts) do
    sup_name = opts[:name] || :self
    worker_spec = S.Spec.worker(mod, [init_arg], [restart: :temporary, shutdown: 5000])
    spec = S.Spec.supervise([worker_spec], strategy: :simple_one_for_one, max_restarts: 0, max_seconds: 1)
    {sup_name, Callback, [spec]}
  end

  def handle_call(:checkout_nonblocking, _from,
                  state(reserved: reserved, ondemand: ondemand, all: all, available: available) = s) do
    case available do
      [pid | pids] -> reply_with_available_worker(pid, pids, s)
      []           ->
        if map_size(all) < reserved + ondemand do
          reply_with_ondemand_worker(s)
        else
          {:reply, nil, s}
        end
    end
  end
  def handle_call(:checkout, from,
                  state(reserved: reserved, ondemand: ondemand, all: all, available: available, waiting: waiting) = s) do
    case available do
      [pid | pids] -> reply_with_available_worker(pid, pids, s)
      []           ->
        if map_size(all) < reserved + ondemand do
          reply_with_ondemand_worker(s)
        else
          {:noreply, state(s, waiting: :queue.in(from, waiting))}
        end
    end
  end
  def handle_call(:status, _from,
                  state(reserved: reserved, ondemand: ondemand, all: all, available: available, working: working) = s) do
    r = %{
      reserved:  reserved,
      ondemand:  ondemand,
      children:  map_size(all),
      available: length(available),
      working:   map_size(working),
    }
    {:reply, r, s}
  end
  def handle_call({:start_child, _}, _from, s) do
    {:reply, {:error, :pool_sup}, s}
  end
  def handle_call({:terminate_child, _}, _from, s) do
    # returns `:simple_one_for_one` to obey type contract of `Supervisor.terminate_child/2`
    {:reply, {:error, :simple_one_for_one}, s}
  end
  def handle_call(msg, from, state(sup_state: sup_state) = s) do
    {:reply, reply, new_sup_state} = :supervisor.handle_call(msg, from, sup_state)
    {:reply, reply, state(s, sup_state: new_sup_state)}
  end

  defunp reply_with_available_worker(pid :: pid, pids :: [pid], state(working: working) = s :: state) :: {:reply, pid, state} do
    {:reply, pid, state(s, working: PidSet.put(working, pid), available: pids)}
  end

  defunp reply_with_ondemand_worker(state(all: all, working: working, sup_state: sup_state) = s :: state) :: {:reply, pid, state} do
    {new_child_pid, new_sup_state} = start_child(sup_state)
    s2 = state(s, all: PidSet.put(all, new_child_pid), working: PidSet.put(working, new_child_pid), sup_state: new_sup_state)
    {:reply, new_child_pid, s2}
  end

  def handle_cast({:checkin, pid},
                  state(reserved:  reserved,
                        ondemand:  ondemand,
                        all:       all,
                        working:   working,
                        available: available,
                        waiting:   waiting) = s) do
    if PidSet.member?(working, pid) do
      size_all = map_size(all)
      new_state = cond do
        size_all > reserved + ondemand ->
          terminate_checked_in_child(s, pid)
        size_all > reserved ->
          case :queue.out(waiting) do
            {:empty, _}                  -> terminate_checked_in_child(s, pid)
            {{:value, client}, waiting2} -> send_reply_with_checked_in_child(s, pid, client, waiting2)
          end
        :otherwise ->
          case :queue.out(waiting) do
            {:empty, _}                  -> state(s, working: PidSet.delete(working, pid), available: [pid | available])
            {{:value, client}, waiting2} -> send_reply_with_checked_in_child(s, pid, client, waiting2)
          end
        end
      {:noreply, new_state}
    else
      {:noreply, s}
    end
  end
  def handle_cast({:cancel_waiting, pid}, state(waiting: waiting) = s) do
    new_waiting = :queue.filter(&(&1 == pid), waiting)
    {:noreply, state(s, waiting: new_waiting)}
  end
  def handle_cast({:change_capacity, new_reserved, new_ondemand}, s) do
    s2 = case {new_reserved, new_ondemand} do
      {nil, o  } -> state(s,              ondemand: o)
      {r  , nil} -> state(s, reserved: r             )
      {r  , o  } -> state(s, reserved: r, ondemand: o)
    end
    {:noreply, handle_capacity_change(s2)}
  end

  defunp terminate_checked_in_child(state(all: all, working: working, sup_state: sup_state) = s :: state, pid :: pid) :: state do
    state(s, all: PidSet.delete(all, pid), working: PidSet.delete(working, pid), sup_state: terminate_child(pid, sup_state))
  end

  defunp send_reply_with_checked_in_child(s :: state, pid :: pid, client :: client, waiting :: client_queue) :: state do
    GenServer.reply(client, pid)
    state(s, waiting: waiting)
  end

  defunp handle_capacity_change(state(available: available) = s :: state) :: state do
    if Enum.empty?(available) do
      send_reply_to_waiting_clients_by_spawn(s)
    else
      terminate_extra_children(s) # As `available` worker exists, no client is currently waiting
    end
    |> restock_children_upto_reserved
  end

  defunp send_reply_to_waiting_clients_by_spawn(state(reserved: reserved,
                                                      ondemand: ondemand,
                                                      all:      all,
                                                      waiting:  waiting) = s :: state) :: state do
    case :queue.out(waiting) do
      {:empty, _}                  -> s
      {{:value, client}, waiting2} ->
        if map_size(all) < reserved + ondemand do
          send_reply_with_new_child(s, client, waiting2) |> send_reply_to_waiting_clients_by_spawn
        else
          s
        end
    end
  end

  defunp terminate_extra_children(state(reserved: reserved, all: all, available: available, sup_state: sup_state) = s :: state) :: state do
    case available do
      []           -> s
      [pid | pids] ->
        if map_size(all) > reserved do
          state(s, all: PidSet.delete(all, pid), available: pids, sup_state: terminate_child(pid, sup_state)) |> terminate_extra_children
        else
          s
        end
    end
  end

  defunp restock_children_upto_reserved(state(reserved: reserved, all: all) = s :: state) :: state do
    if map_size(all) < reserved do
      restock_child(s) |> restock_children_upto_reserved
    else
      s
    end
  end

  def handle_info(msg, state(sup_state: sup_state) = s) do
    {:noreply, new_sup_state} = :supervisor.handle_info(msg, sup_state)
    s2 = state(s, sup_state: new_sup_state)
    s3 = case msg do
      {:EXIT, pid, _reason} -> handle_exit(s2, pid)
      _                     -> s2
    end
    {:noreply, s3}
  end

  defunp handle_exit(state(all: all) = s :: state, pid :: pid) :: state do
    if PidSet.member?(all, pid) do
      handle_child_exited(s, pid)
    else
      s
    end
  end

  defunp handle_child_exited(state(reserved:  reserved,
                                   ondemand:  ondemand,
                                   all:       all,
                                   working:   working,
                                   available: available,
                                   waiting:   waiting) = s :: state,
                             child_pid :: pid) :: state do
    {working2, available2} =
      case PidSet.member?(working, child_pid) do
        true  -> {PidSet.delete(working, child_pid), available}
        false -> {working, List.delete(available, child_pid)}
      end
    all2 = PidSet.delete(all, child_pid)
    s2 = state(s, all: all2, working: working2, available: available2)
    size_all = map_size(all2)
    cond do
      size_all >= reserved + ondemand ->
        s2
      size_all >= reserved ->
        case :queue.out(waiting) do
          {:empty, _}                  -> s2
          {{:value, client}, waiting2} -> send_reply_with_new_child(s2, client, waiting2)
        end
      :otherwise ->
        case :queue.out(waiting) do
          {:empty, _}                  -> restock_child(s2)
          {{:value, client}, waiting2} -> send_reply_with_new_child(s2, client, waiting2)
        end
    end
  end

  defunp send_reply_with_new_child(state(all: all, working: working, sup_state: sup_state) = s :: state,
                                   client :: client, waiting :: client_queue) :: state do
    {pid, new_sup_state} = start_child(sup_state)
    GenServer.reply(client, pid)
    state(s, all: PidSet.put(all, pid), working: PidSet.put(working, pid), waiting: waiting, sup_state: new_sup_state)
  end

  defunp restock_child(state(all: all, available: available, sup_state: sup_state) = s :: state) :: state do
    {pid, new_sup_state} = start_child(sup_state)
    state(s, all: PidSet.put(all, pid), available: [pid | available], sup_state: new_sup_state)
  end

  defunp start_child(sup_state :: sup_state) :: {pid, sup_state} do
    {:reply, {:ok, pid}, new_sup_state} = :supervisor.handle_call({:start_child, []}, self, sup_state)
    {pid, new_sup_state}
  end

  defunp terminate_child(pid :: pid, sup_state :: sup_state) :: sup_state do
    {:reply, :ok, new_sup_state} = :supervisor.handle_call({:terminate_child, pid}, self, sup_state)
    new_sup_state
  end

  def terminate(reason, state(sup_state: sup_state)) do
    :supervisor.terminate(reason, sup_state)
  end

  def code_change(old_vsn, state(sup_state: sup_state) = s, extra) do
    case :supervisor.code_change(old_vsn, sup_state, extra) do
      {:ok, new_sup_state} -> {:ok, state(s, sup_state: new_sup_state)}
      {:error, reason}     -> {:error, reason}
    end
  end

  # We need to define `format_status` to pretend as if it's an ordinary supervisor when `sys:get_status/1` is called
  @doc false
  def format_status(:terminate, [_pdict, s                          ]), do: s
  def format_status(:normal   , [_pdict, state(sup_state: sup_state)]), do: [{:data, [{'State', sup_state}]}]
end
