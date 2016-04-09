use Croma

defmodule PoolSup do
  @moduledoc """
  This module defines a supervisor process that is specialized to manage pool of workers.

  - Process defined by this module behaves as a `:simple_one_for_one` supervisor.
  - Worker processes are spawned using a callback module that implements `PoolSup.Worker` behaviour.
  - The `PoolSup` process manages which child processes are in use and which are not.
  - Functions to request pid of a child process that is not in use are also defined (`checkout/2`, `checkout_nonblock/2`).

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

      iex(2)> {:ok, pool_sup_pid} = PoolSup.start_link(MyWorker, {:worker, :arg}, 3, [name: :my_pool])

  Each worker process is started using `MyWorker.start_link({:worker, :arg})`.
  Then we can get a pid of a child currently not in use:

      iex(3)> child_pid = PoolSup.checkout(:my_pool)
      iex(4)> do_something(child_pid)
      iex(5)> PoolSup.checkin(:my_pool, child_pid)

  Don't forget to return the `child_pid` when finished; for simple use cases `PoolSup.transaction/3` comes in handy.

  ### Usage within supervision tree

  The following code snippet spawns a supervisor that has `PoolSup` process as one of its children.
  The `PoolSup` process manages 5 worker processes and they will be started by `MyWorker.start_link({:worker, :arg})`.

      chilldren = [
        ...
        Supervisor.Spec.supervisor(PoolSup, [MyWorker, {:worker, :arg}, 5]),
        ...
      ]
      Supervisor.start_link(children, [strategy: :one_for_one])

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
    defun from_list(pids :: [pid])      :: t      , do: Enum.into(pids, %{}, &{&1, true})
  end

  @type  pool         :: pid | GS.name
  @type  options      :: [name: GS.name]
  @typep client_queue :: :queue.queue({pid, reference})
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
  - `capacity` is the initial number of workers this `PoolSup` process holds.
  - Currently only `:name` option is supported for name registration.
  """
  defun start_link(worker_module :: g[module], worker_init_arg :: term, capacity :: g[non_neg_integer], options :: options \\ []) :: GS.on_start do
    GS.start_link(__MODULE__, {worker_module, worker_init_arg, capacity, options}, gen_server_opts(options))
  end

  defunp gen_server_opts(opts :: options) :: [name: GS.name] do
    Enum.filter(opts, &match?({:name, _}, &1))
  end

  @doc """
  Checks out a worker pid that is currently not used from a pool.

  If no available worker process exists, the caller is blocked until either
  - any process becomes available, or
  - timeout is reached.
  """
  defun checkout(pool :: pool, timeout :: timeout \\ 5000) :: nil | pid do
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
  defun checkout_nonblock(pool :: pool, timeout :: timeout \\ 5000) :: nil | pid do
    GenServer.call(pool, :checkout_nonblock, timeout)
  end

  @doc """
  Checks in an in-use worker pid and make it available to others.
  """
  defun checkin(pool :: pool, pid :: g[pid]) :: :ok do
    GenServer.cast(pool, {:checkin, pid})
  end

  @doc """
  Temporarily checks out a worker pid, executes the given function using the pid, and checks in the pid.

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
  defun status(pool :: pool) :: %{children: nni, available: nni, working: nni, reserved: nni} when nni: non_neg_integer do
    GenServer.call(pool, :status)
  end

  @doc """
  Changes capacity (number of worker processes) of a pool.

  If `new_capacity` is more than the current capacity, new processes are immediately spawned and become available.
  Note that, as is the same throughout the OTP framework, spawning processes under supervisor is synchronous operation.
  Therefore increasing large number of capacity at once may make a pool unresponsive for a while.

  If `new_capacity` is less than the current capacity, the pool tries to shutdown workers that are not in use.
  Processes currently in use are never interrupted.
  If number of in-use workers is more than `new_capacity`, reducing further is delayed until any worker process is checked in.
  """
  defun change_capacity(pool :: pool, new_capacity :: g[non_neg_integer]) :: :ok do
    GenServer.call(pool, {:change_capacity, new_capacity})
  end

  #
  # gen_server callbacks
  #
  def init({mod, init_arg, capacity, opts}) do
    {:ok, sup_state} = :supervisor.init(supervisor_init_arg(mod, init_arg, opts))
    {:ok, make_state(capacity, sup_state)}
  end

  defp supervisor_init_arg(mod, init_arg, opts) do
    sup_name = opts[:name] || :self
    worker_spec = S.Spec.worker(mod, [init_arg], [restart: :temporary, shutdown: 5000])
    spec = S.Spec.supervise([worker_spec], strategy: :simple_one_for_one, max_restarts: 0, max_seconds: 1)
    {sup_name, Callback, [spec]}
  end

  defunp make_state(capacity :: non_neg_integer, sup_state :: sup_state) :: state do
    {pids, new_sup_state} = prepare_children(capacity, [], sup_state)
    all = PidSet.from_list(pids)
    state(reserved: capacity, all: all, working: PidSet.new, available: pids, waiting: :queue.new, sup_state: new_sup_state)
  end

  defunp prepare_children(capacity :: non_neg_integer, pids :: [pid], sup_state :: sup_state) :: {[pid], sup_state} do
    if capacity == 0 do
      {pids, sup_state}
    else
      {pid, new_sup_state} = start_child(sup_state)
      prepare_children(capacity - 1, [pid | pids], new_sup_state)
    end
  end

  def handle_call(:checkout_nonblock, _from, state(available: available) = s) do
    case available do
      [pid | pids] -> reply_with_pid(pid, pids, s)
      []           -> {:reply, nil, s}
    end
  end
  def handle_call(:checkout, from, state(available: available, waiting: waiting) = s) do
    case available do
      [pid | pids] -> reply_with_pid(pid, pids, s)
      []           ->
        new_state = state(s, waiting: :queue.in(from, waiting))
        {:noreply, new_state}
    end
  end
  def handle_call(:status, _from,
                  state(reserved: reserved, all: all, available: available, working: working) = s) do
    r = %{
      reserved:  reserved,
      children:  map_size(all),
      available: length(available),
      working:   map_size(working),
    }
    {:reply, r, s}
  end
  def handle_call({:change_capacity, new_reserved}, _from, state(all: all) = s) do
    s2 = state(s, reserved: new_reserved)
    case new_reserved - map_size(all) do
      0                  -> {:reply, :ok, s2}
      diff when diff > 0 -> {:reply, :ok, increase_children(s2)}
      _                  -> {:reply, :ok, decrease_children(s2)}
    end
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

  defunp reply_with_pid(pid :: pid, pids :: [pid], state(working: working) = s :: state) :: {:reply, pid, state} do
    {:reply, pid, state(s, working: PidSet.put(working, pid), available: pids)}
  end

  defunp increase_children(state(reserved: reserved, all: all, working: working, available: available, waiting: waiting, sup_state: sup_state) = s :: state) :: state do
    if map_size(all) == reserved do
      s
    else
      {pid, new_sup_state} = start_child(sup_state)
      all2 = PidSet.put(all, pid)
      new_state =
        case :queue.out(waiting) do
          {{:value, wait_pid}, waiting2} ->
            GenServer.reply(wait_pid, pid)
            state(s, all: all2, working: PidSet.put(working, pid), waiting: waiting2, sup_state: new_sup_state)
          {:empty, _} ->
            state(s, all: all2, available: [pid | available], sup_state: new_sup_state)
        end
      increase_children(new_state)
    end
  end

  defunp start_child(sup_state :: sup_state) :: {pid, sup_state} do
    {:reply, {:ok, pid}, new_sup_state} = :supervisor.handle_call({:start_child, []}, self, sup_state)
    {pid, new_sup_state}
  end

  defunp decrease_children(state(reserved: reserved, all: all, available: available, sup_state: sup_state) = s :: state) :: state do
    if map_size(all) == reserved do
      s
    else
      case available do
        []           -> s # can't decrease children now
        [pid | pids] ->
          new_sup_state = terminate_child(pid, sup_state)
          new_state = state(s, all: PidSet.delete(all, pid), available: pids, sup_state: new_sup_state)
          decrease_children(new_state)
      end
    end
  end

  defunp terminate_child(pid :: pid, sup_state :: sup_state) :: sup_state do
    {:reply, :ok, new_sup_state} = :supervisor.handle_call({:terminate_child, pid}, self, sup_state)
    new_sup_state
  end

  def handle_cast({:checkin, pid},
                  state(reserved: reserved,
                        all: all,
                        working: working,
                        available: available,
                        waiting: waiting,
                        sup_state: sup_state) = s) do
    if PidSet.member?(working, pid) do
      new_state =
        if map_size(all) == reserved do
          case :queue.out(waiting) do
            {{:value, wait_pid}, waiting2} ->
              GenServer.reply(wait_pid, pid)
              state(s, waiting: waiting2)
            {:empty, _} ->
              working2 = PidSet.delete(working, pid)
              state(s, working: working2, available: [pid | available])
          end
        else # map_size(all) > reserved: try to decrease children
          working2 = PidSet.delete(working, pid)
          new_sup_state = terminate_child(pid, sup_state)
          state(s, all: PidSet.delete(all, pid), working: working2, sup_state: new_sup_state)
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
                                   all:       all,
                                   working:   working,
                                   available: available,
                                   waiting:   waiting,
                                   sup_state: sup_state) = s :: state,
                             child_pid :: pid) :: state do
    {working2, available2} =
      case PidSet.member?(working, child_pid) do
        true  -> {PidSet.delete(working, child_pid), available}
        false -> {working, List.delete(available, child_pid)}
      end
    all2 = PidSet.delete(all, child_pid)
    if map_size(all) == reserved do
      {new_child_pid, new_sup_state} = start_child(sup_state)
      all3 = PidSet.put(all2, new_child_pid)
      case :queue.out(waiting) do
        {{:value, wait_pid}, waiting2} ->
          GenServer.reply(wait_pid, new_child_pid)
          working3 = PidSet.put(working2, new_child_pid)
          state(s, all: all3, working: working3, available: available2, waiting: waiting2, sup_state: new_sup_state)
        {:empty, _} ->
          available3 = [new_child_pid | available2]
          state(s, all: all3, working: working2, available: available3, sup_state: new_sup_state)
      end
    else
      state(s, all: all2, working: working2, available: available2)
    end
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
