use Croma

defmodule PoolSup do
  @moduledoc """
  TODO
  """

  alias Supervisor, as: S
  alias GenServer, as: GS
  use GS

  defmodule Callback do
    # The sole purpose of this module is to suppress dialyzer warning;
    # using `Supervisor.Default` results in a warning due to (seemingly) incorrect typespec of
    # `supervisor:init/1` (which is an implementation of `gen_server:init/1` callback, not callback of supervisor behaviour).
    @behaviour :supervisor
    def init([arg]), do: arg
  end

  defmodule PidSet do
    @type t :: %{pid => true}
    defun new                           :: t      , do: %{}
    defun member?(set :: t, pid :: pid) :: boolean, do: Map.has_key?(set, pid)
    defun put(set :: t, pid :: pid)     :: t      , do: Map.put(set, pid, true)
    defun delete(set :: t, pid :: pid)  :: t      , do: Map.delete(set, pid)
    defun from_list(pids :: [pid])      :: t      , do: Enum.into(pids, %{}, &{&1, true})
  end

  @type  options   :: [name: GS.name]
  @typep sup_state :: any

  require Record
  Record.defrecordp :state, [
    :all,
    :working,
    :available,
    :capacity_to_decrease,
    :sup_state,
  ]
  @typep state :: record(:state,
    all:                  PidSet.t,
    working:              PidSet.t,
    available:            [pid],
    capacity_to_decrease: non_neg_integer,
    sup_state:            sup_state,
  )

  @doc """
  TODO
  """
  defun start_link(worker_module :: g[module], worker_init_arg :: term, capacity :: g[non_neg_integer], opts :: options \\ []) :: GS.on_start do
    GS.start_link(__MODULE__, {worker_module, worker_init_arg, capacity, opts}, gen_server_opts(opts))
  end

  defunp gen_server_opts(opts :: options) :: [name: GS.name] do
    case opts[:name] do
      nil  -> []
      name -> [name: name]
    end
  end

  # gen_server callbacks
  def init({mod, init_arg, capacity, opts}) do
    case :supervisor.init(supervisor_init_arg(mod, init_arg, opts)) do
      {:ok, sup_state} -> {:ok, make_state(capacity, sup_state)}
      other            -> other
    end
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
    state(all: all, working: PidSet.new, available: pids, capacity_to_decrease: 0, sup_state: new_sup_state)
  end

  defunp prepare_children(capacity :: non_neg_integer, pids :: [pid], sup_state :: sup_state) :: {[pid], sup_state} do
    if capacity == 0 do
      {pids, sup_state}
    else
      {pid, new_sup_state} = start_child(sup_state)
      prepare_children(capacity - 1, [pid | pids], new_sup_state)
    end
  end

  def handle_call(:checkout, _from, state(working: working, available: available) = s) do
    case available do
      []        -> {:reply, nil, s}
      [pid | pids] ->
        new_state = state(s, working: PidSet.put(working, pid), available: pids)
        {:reply, pid, new_state}
    end
  end
  def handle_call(:status, _from,
                  state(all: all, available: available, working: working, capacity_to_decrease: to_decrease) = s) do
    current_capacity = map_size(all)
    r = %{
      current_capacity: current_capacity,
      desired_capacity: current_capacity - to_decrease,
      available:        length(available),
      working:          map_size(working),
    }
    {:reply, r, s}
  end
  def handle_call({:change_capacity, new_capacity}, _from, state(all: all) = s) do
    case new_capacity - map_size(all) do
      0 ->
        {:reply, :ok, state(s, capacity_to_decrease: 0)}
      to_increase when to_increase > 0 ->
        new_state = increase_children(to_increase, s)
        {:reply, :ok, new_state}
      to_decrease ->
        new_state = decrease_children(-to_decrease, s)
        {:reply, :ok, new_state}
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

  defunp increase_children(to_increase :: non_neg_integer, state(all: all, available: available, sup_state: sup_state) = s :: state) :: state do
    if to_increase == 0 do
      state(s, capacity_to_decrease: 0)
    else
      {pid, new_sup_state} = start_child(sup_state)
      new_state = state(s, all: PidSet.put(all, pid), available: [pid | available], sup_state: new_sup_state)
      increase_children(to_increase - 1, new_state)
    end
  end

  defunp start_child(sup_state :: sup_state) :: {pid, sup_state} do
    {:reply, {:ok, pid}, new_sup_state} = :supervisor.handle_call({:start_child, []}, self, sup_state)
    {pid, new_sup_state}
  end

  defunp decrease_children(to_decrease :: non_neg_integer, state(all: all, available: available, sup_state: sup_state) = s :: state) :: state do
    if to_decrease == 0 do
      state(s, capacity_to_decrease: 0)
    else
      case available do
        []           -> state(s, capacity_to_decrease: to_decrease)
        [pid | pids] ->
          new_sup_state = terminate_child(pid, sup_state)
          new_state = state(s, all: PidSet.delete(all, pid), available: pids, sup_state: new_sup_state)
          decrease_children(to_decrease - 1, new_state)
      end
    end
  end

  defunp terminate_child(pid :: pid, sup_state :: sup_state) :: sup_state do
    {:reply, :ok, new_sup_state} = :supervisor.handle_call({:terminate_child, pid}, self, sup_state)
    new_sup_state
  end

  def handle_cast({:checkin, pid},
                  state(all: all, working: working, available: available, capacity_to_decrease: to_decrease, sup_state: sup_state) = s) do
    if PidSet.member?(working, pid) do
      working2 = PidSet.delete(working, pid)
      new_state =
        if to_decrease == 0 do
          state(s, working: working2, available: [pid | available])
        else
          new_sup_state = terminate_child(pid, sup_state)
          state(s, all: PidSet.delete(all, pid), working: working2, capacity_to_decrease: to_decrease - 1, sup_state: new_sup_state)
        end
      {:noreply, new_state}
    else
      {:noreply, s}
    end
  end
  def handle_cast(msg, state(sup_state: sup_state)) do
    :supervisor.handle_cast(msg, sup_state)
  end

  def handle_info(msg, state(sup_state: sup_state) = s) do
    case :supervisor.handle_info(msg, sup_state) do
      {:noreply, new_sup_state} ->
        s2 = state(s, sup_state: new_sup_state)
        new_state = case msg do
          {:EXIT, pid, _reason} -> handle_exit(s2, pid)
          _                     -> s2
        end
        {:noreply, new_state}
      {:stop, reason, new_sup_state} ->
        {:stop, reason, state(s, sup_state: new_sup_state)}
    end
  end

  defunp handle_exit(state(all: all) = s :: state, pid :: pid) :: state do
    if PidSet.member?(all, pid) do
      handle_child_exited(s, pid)
    else
      s
    end
  end

  defunp handle_child_exited(state(all:                  all,
                                   working:              working,
                                   available:            available,
                                   capacity_to_decrease: to_decrease,
                                   sup_state:            sup_state) = s :: state,
                             child_pid :: pid) :: state do
    {working2, available2} =
      case PidSet.member?(working, child_pid) do
        true  -> {PidSet.delete(working, child_pid), available}
        false -> {working, List.delete(available, child_pid)}
      end
    all2 = PidSet.delete(all, child_pid)
    if to_decrease == 0 do
      {new_child_pid, new_sup_state} = start_child(sup_state)
      all3 = PidSet.put(all2, new_child_pid)
      available3 = [new_child_pid | available2]
      state(s, all: all3, working: working2, available: available3, sup_state: new_sup_state)
    else
      state(s, all: all2, working: working2, available: available2, capacity_to_decrease: to_decrease - 1)
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
  def format_status(:terminate, [_pdict, s                          ]), do: s
  def format_status(:normal   , [_pdict, state(sup_state: sup_state)]), do: [{:data, [{'State', sup_state}]}]

  # external API
  @doc """
  TODO
  """
  defun checkout(pool :: GS.name, timeout :: timeout \\ 5000) :: nil | pid do
    GenServer.call(pool, :checkout, timeout)
  end

  @doc """
  TODO
  """
  defun checkin(pool :: GS.name, pid :: g[pid]) :: :ok do
    GenServer.cast(pool, {:checkin, pid})
  end

  @doc """
  TODO
  """
  defun status(pool :: GS.name) :: %{current_capacity: ni, desired_capacity: ni, available: ni, working: ni} when ni: non_neg_integer do
    GenServer.call(pool, :status)
  end

  @doc """
  TODO
  """
  defun change_capacity(pool :: GS.name, new_capacity :: g[non_neg_integer]) :: :ok do
    GenServer.call(pool, {:change_capacity, new_capacity})
  end
end
