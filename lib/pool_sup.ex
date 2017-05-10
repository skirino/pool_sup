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
  - Run-time configuration of pool size: `change_capacity/3`.
  - Load-balancing using multiple pools: `PoolSup.Multi`.

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

      iex(3)> worker_pid = PoolSup.checkout(:my_pool)
      iex(4)> do_something(worker_pid)
      iex(5)> PoolSup.checkin(:my_pool, worker_pid)

  Don't forget to return the `worker_pid` when finished; for simple use cases `PoolSup.transaction/3` comes in handy.

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
      PoolSup.checkin(pool_sup_pid, w2)                # `w2` is kept alive for the subsequent checkout
      PoolSup.checkin(pool_sup_pid, w3)                # `w3` is kept alive for the subsequent checkout

  ## Usage within supervision tree

  The following code snippet spawns a supervisor that has `PoolSup` process as one of its children:

      chilldren = [
        ...
        Supervisor.Spec.supervisor(PoolSup, [MyWorker, {:worker, :arg}, 5, 3]),
        ...
      ]
      Supervisor.start_link(children, [strategy: :one_for_one])

  The `PoolSup` process initially has 5 workers and can temporarily have up to 8.
  All workers are started by `MyWorker.start_link({:worker, :arg})`.

  You can of course define a wrapper function of `PoolSup.start_link/4` and use it in your supervisor spec.
  """

  alias Supervisor, as: S
  alias GenServer, as: GS
  use GS
  alias PoolSup.{PidSet, PidRefSet, ClientQueue, Callback}
  alias PoolSup.CustomSupHelper, as: H
  require H

  @type  pool      :: pid | GS.name
  @type  options   :: [name: GS.name]
  @typep sup_state :: H.sup_state

  require Record
  Record.defrecordp :state, [
    :sup_state,
    :reserved,
    :ondemand,
    :all,
    :working,
    :available,
    :waiting,
  ]
  @typep state :: record(:state,
    sup_state: sup_state,
    reserved:  non_neg_integer,
    ondemand:  non_neg_integer,
    all:       PidSet.t,
    working:   PidRefSet.t,
    available: [pid],
    waiting:   ClientQueue.t,
  )

  #
  # client API
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
    GS.start_link(__MODULE__, {worker_module, worker_init_arg, reserved, ondemand, options}, H.gen_server_opts(options))
  end

  @doc """
  Checks out a worker pid that is currently not used.

  If no available worker process exists, the caller is blocked until either
  - any process becomes available, or
  - timeout is reached.

  Note that when a pid is checked-out it must eventually be checked-in or die,
  in order to correctly keep track of working processes and avoid process leaks.
  For this purpose it's advisable to either

  - link the checked-out process and the process who is going to check-in that process, or
  - implement your worker to check-in itself at the end of each job.
  """
  defun checkout(pool :: pool, timeout :: timeout \\ 5000) :: pid do
    cancel_ref = make_ref()
    try do
      GenServer.call(pool, {:checkout, cancel_ref}, timeout)
    catch
      :exit, {:timeout, _} = reason ->
        GenServer.cast(pool, {:cancel_waiting, self(), cancel_ref})
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
  Checks out a worker pid, creates a link to the worker, executes the given function using the pid, and finally checks-in and unlink.

  The `timeout` parameter is used only in the checkout step; time elapsed during other steps are not counted.
  """
  defun transaction(pool :: pool, f :: (pid -> a), timeout :: timeout \\ 5000) :: a when a: term do
    pid = checkout(pool, timeout)
    try do
      Process.link(pid)
      f.(pid)
    after
      checkin(pool, pid)
      Process.unlink(pid)
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

  - If current number of workers are less than `reserved`, the pool spawns new workers to ensure `reserved` workers are available.
    Note that, as is the same throughout the OTP framework, spawning processes under a supervisor is synchronous operation.
    Therefore increasing `reserved` too many at once may make the pool unresponsive for a while.
  - When increasing maximum capacity (`reserved + ondemand`) and if any client process is being checking-out in a blocking manner,
    then the newly-spawned process is returned to the client.
  - When decreasing capacity, the pool tries to shutdown extra workers that are not in use.
    Processes currently in use are never interrupted.
    If number of in-use workers is more than the desired capacity, terminating further is delayed until any worker process is checked in.
  """
  defun change_capacity(pool :: pool, new_reserved :: nil | non_neg_integer, new_ondemand :: nil | non_neg_integer) :: :ok do
    (_pool, nil, nil) -> :ok
    (pool , r  , o  ) when H.is_nil_or_nni(r) and H.is_nil_or_nni(o) ->
      GenServer.cast(pool, {:change_capacity, r, o})
  end

  #
  # gen_server callbacks
  #
  def init({mod, init_arg, reserved, ondemand, opts}) do
    {:ok, sup_state} = :supervisor.init(supervisor_init_arg(mod, init_arg, opts))
    s = state(sup_state: sup_state, reserved: reserved, ondemand: ondemand, all: PidSet.new(), working: PidRefSet.new(), available: [], waiting: ClientQueue.new())
    {:ok, restock_children_upto_reserved(s)}
  end

  defp supervisor_init_arg(mod, init_arg, opts) do
    sup_name = opts[:name] || :self
    worker_spec = S.Spec.worker(mod, [init_arg], [restart: :temporary, shutdown: 5000])
    spec = S.Spec.supervise([worker_spec], strategy: :simple_one_for_one, max_restarts: 0, max_seconds: 1)
    {sup_name, Callback, [spec]}
  end

  def handle_call(:checkout_nonblocking, {_, ref},
                  state(reserved: reserved, ondemand: ondemand, all: all, available: available) = s) do
    # In nonblocking checkout we use `ref` in `from` tuple (as microoptimization to avoid creating new one),
    # since in this case no cancellation would ever happen later and thus any reference would be OK.
    case available do
      [pid | pids] ->
        reply_with_available_worker(pid, pids, ref, s)
      [] ->
        if map_size(all) < reserved + ondemand do
          reply_with_ondemand_worker(s, ref)
        else
          {:reply, nil, s}
        end
    end
  end
  def handle_call({:checkout, cancel_ref}, from,
                  state(reserved: reserved, ondemand: ondemand, all: all, available: available) = s) do
    case available do
      [pid | pids] -> reply_with_available_worker(pid, pids, cancel_ref, s)
      []           ->
        if map_size(all) < reserved + ondemand do
          reply_with_ondemand_worker(s, cancel_ref)
        else
          {:noreply, enqueue_client(s, from, cancel_ref)}
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
      working:   PidRefSet.size(working),
    }
    {:reply, r, s}
  end

  H.handle_call_default_clauses

  defunp reply_with_available_worker(pid :: pid, pids :: [pid], cancel_ref :: reference, state(working: working) = s :: state) :: {:reply, pid, state} do
    {:reply, pid, state(s, working: PidRefSet.put(working, pid, cancel_ref), available: pids)}
  end

  defunp reply_with_ondemand_worker(state(sup_state: sup_state, all: all, working: working) = s :: state, cancel_ref :: reference) :: {:reply, pid, state} do
    {new_child_pid, new_sup_state} = H.start_child(sup_state)
    s2 = state(s, sup_state: new_sup_state, all: PidSet.put(all, new_child_pid), working: PidRefSet.put(working, new_child_pid, cancel_ref))
    {:reply, new_child_pid, s2}
  end

  def handle_cast({:checkin, pid}, state(working: working) = s) do
    if PidRefSet.member_pid?(working, pid) do
      {:noreply, handle_worker_checkin(s, pid)}
    else
      {:noreply, s}
    end
  end
  def handle_cast({:cancel_waiting, pid, cancel_ref}, state(working: working) = s) do
    s2 =
      case PidRefSet.get_pid_by_ref(working, cancel_ref) do
        nil        -> cancel_client(s, pid, cancel_ref)
        worker_pid ->
          # the client timed-out but `GenServer.reply/2` has already been called; need to reclaim the `worker_pid`
          handle_worker_checkin(s, worker_pid)
      end
    {:noreply, s2}
  end
  def handle_cast({:change_capacity, new_reserved, new_ondemand}, s) do
    s2 =
      case {new_reserved, new_ondemand} do
        {nil, o  } -> state(s,              ondemand: o)
        {r  , nil} -> state(s, reserved: r             )
        {r  , o  } -> state(s, reserved: r, ondemand: o)
      end
    {:noreply, handle_capacity_change(s2)}
  end

  defunp handle_worker_checkin(state(reserved:  reserved,
                                     ondemand:  ondemand,
                                     all:       all,
                                     working:   working,
                                     available: available) = s :: state,
                               pid :: pid) :: state do
    size_all = map_size(all)
    cond do
      size_all > reserved + ondemand ->
        terminate_checked_in_child(s, pid)
      size_all > reserved ->
        case dequeue_client(s) do
          nil                    -> terminate_checked_in_child(s, pid)
          {from, cancel_ref, s2} -> send_reply_with_checked_in_child(s2, from, cancel_ref, pid)
        end
      :otherwise ->
        case dequeue_client(s) do
          nil                    -> state(s, working: PidRefSet.delete_by_pid(working, pid), available: [pid | available])
          {from, cancel_ref, s2} -> send_reply_with_checked_in_child(s2, from, cancel_ref, pid)
        end
    end
  end

  defunp terminate_checked_in_child(state(sup_state: sup_state, all: all, working: working) = s :: state, pid :: pid) :: state do
    state(s, sup_state: H.terminate_child(pid, sup_state), all: PidSet.delete(all, pid), working: PidRefSet.delete_by_pid(working, pid))
  end

  defunp send_reply_with_checked_in_child(state(working: working) = s :: state,
                                          from       :: GenServer.from,
                                          cancel_ref :: reference,
                                          pid        :: pid) :: state do
    GenServer.reply(from, pid)
    state(s, working: PidRefSet.put(working, pid, cancel_ref))
  end

  defunp handle_capacity_change(state(available: available) = s :: state) :: state do
    case available do
      [] -> send_reply_to_waiting_clients_by_spawn(s)
      _  -> terminate_extra_children(s) # As `available` worker exists, no client is currently waiting
    end
    |> restock_children_upto_reserved()
  end

  defunp send_reply_to_waiting_clients_by_spawn(state(reserved: reserved,
                                                      ondemand: ondemand,
                                                      all:      all) = s :: state) :: state do
    if map_size(all) < reserved + ondemand do
      case dequeue_client(s) do
        nil                    -> s
        {from, cancel_ref, s2} -> send_reply_with_new_child(s2, from, cancel_ref) |> send_reply_to_waiting_clients_by_spawn()
      end
    else
      s
    end
  end

  defunp terminate_extra_children(state(sup_state: sup_state, reserved: reserved, all: all, available: available) = s :: state) :: state do
    case available do
      []           -> s
      [pid | pids] ->
        if map_size(all) > reserved do
          state(s, sup_state: H.terminate_child(pid, sup_state), all: PidSet.delete(all, pid), available: pids) |> terminate_extra_children()
        else
          s
        end
    end
  end

  defunp restock_children_upto_reserved(state(reserved: reserved, all: all) = s :: state) :: state do
    if map_size(all) < reserved do
      restock_child(s) |> restock_children_upto_reserved()
    else
      s
    end
  end

  def handle_info(msg, s) do
    s2 =
      case msg do
        {:DOWN, _mref, :process, pid, _reason} -> cancel_client(s, pid, nil)
        {:EXIT, pid, _reason}                  -> H.delegate_info_message_to_supervisor_callback(msg, s) |> handle_exit(pid)
        _                                      -> H.delegate_info_message_to_supervisor_callback(msg, s)
      end
    {:noreply, s2}
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
                                   available: available) = s :: state,
                             child_pid :: pid) :: state do
    {working2, available2} =
      case PidRefSet.member_pid?(working, child_pid) do
        true  -> {PidRefSet.delete_by_pid(working, child_pid), available}
        false -> {working, List.delete(available, child_pid)}
      end
    all2 = PidSet.delete(all, child_pid)
    s2 = state(s, all: all2, working: working2, available: available2)
    size_all = map_size(all2)
    cond do
      size_all >= reserved + ondemand ->
        s2
      size_all >= reserved ->
        case dequeue_client(s2) do
          nil                    -> s2
          {from, cancel_ref, s3} -> send_reply_with_new_child(s3, from, cancel_ref)
        end
      :otherwise ->
        case dequeue_client(s2) do
          nil                    -> restock_child(s2)
          {from, cancel_ref, s3} -> send_reply_with_new_child(s3, from, cancel_ref)
        end
    end
  end

  defunp send_reply_with_new_child(state(sup_state: sup_state, all: all, working: working) = s :: state,
                                   from       :: GenServer.from,
                                   cancel_ref :: reference) :: state do
    {pid, new_sup_state} = H.start_child(sup_state)
    GenServer.reply(from, pid)
    state(s, sup_state: new_sup_state, all: PidSet.put(all, pid), working: PidRefSet.put(working, pid, cancel_ref))
  end

  defunp restock_child(state(sup_state: sup_state, all: all, available: available) = s :: state) :: state do
    {pid, new_sup_state} = H.start_child(sup_state)
    state(s, sup_state: new_sup_state, all: PidSet.put(all, pid), available: [pid | available])
  end

  defunp enqueue_client(state(waiting: waiting) = s :: state, from :: GenServer.from, cancel_ref :: reference) :: state do
    state(s, waiting: ClientQueue.enqueue_and_monitor(waiting, from, cancel_ref))
  end

  defunp dequeue_client(state(waiting: waiting1) = s :: state) :: nil | {GenServer.from, reference, state} do
    case ClientQueue.dequeue_and_demonitor(waiting1) do
      nil                          -> nil
      {from, cancel_ref, waiting2} -> {from, cancel_ref, state(s, waiting: waiting2)}
    end
  end

  defunp cancel_client(state(waiting: waiting) = s :: state, pid :: pid, cancel_ref_or_nil :: nil | reference) :: state do
    state(s, waiting: ClientQueue.cancel(waiting, pid, cancel_ref_or_nil))
  end

  H.code_change_default_clause

  defdelegate terminate(reason, state), to: H
  defdelegate format_status(opt, list), to: H
end
