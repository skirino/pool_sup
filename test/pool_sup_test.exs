defmodule PoolSupTest do
  use ExUnit.Case
  use ExCheck

  defmodule W do
    @behaviour PoolSup.Worker
    use GenServer
    def start_link(_) do
      GenServer.start_link(__MODULE__, {}, [])
    end
  end

  test "should behave as a ordinary supervisor" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, [name: __MODULE__])
    children = Supervisor.which_children(pid)
    assert length(children) == 3
    assert Supervisor.which_children(pid) == children
    assert Supervisor.count_children(pid)[:active] == 3
    assert :supervisor.get_callback_module(pid) == PoolSup.Callback
    :ok = Supervisor.stop(pid)
    refute Process.alive?(pid)
  end

  test "should return error for start_child, terminate_child, restart_child, delete_child" do
    {:ok, pid} = PoolSup.start_link(W, [], 3)
    {_, child, _, _} = Supervisor.which_children(pid) |> hd

    assert Supervisor.start_child(pid, [])        == {:error, :pool_sup}
    assert Supervisor.terminate_child(pid, child) == {:error, :simple_one_for_one}
    assert Supervisor.restart_child(pid, :child)  == {:error, :simple_one_for_one}
    assert Supervisor.delete_child(pid, :child)   == {:error, :simple_one_for_one}

    Supervisor.stop(pid)
    refute Process.alive?(pid)
    refute Process.alive?(child)
  end

  test "should checkout/checkin children" do
    {:ok, pid} = PoolSup.start_link(W, [], 3)
    {:state, _, _, children, _, _} = :sys.get_state(pid)
    [child1, _child2, _child3] = children
    assert Enum.all?(children, &Process.alive?/1)

    # checkin not-working pid => no effect
    assert PoolSup.status(pid) == %{current_capacity: 3, desired_capacity: 3, available: 3, working: 0}
    PoolSup.checkin(pid, self)
    assert PoolSup.status(pid) == %{current_capacity: 3, desired_capacity: 3, available: 3, working: 0}
    PoolSup.checkin(pid, child1)
    assert PoolSup.status(pid) == %{current_capacity: 3, desired_capacity: 3, available: 3, working: 0}

    worker1 = PoolSup.checkout(pid)
    worker2 = PoolSup.checkout(pid)
    worker3 = PoolSup.checkout(pid)
    assert MapSet.new([worker1, worker2, worker3]) == MapSet.new(children)
    assert PoolSup.checkout(pid) == nil

    Supervisor.stop(pid)
    refute Process.alive?(pid)
    refute Enum.any?(children, &Process.alive?/1)
  end

  test "should die when parent process dies" do
    spec = Supervisor.Spec.supervisor(PoolSup, [W, [], 3])
    {:ok, parent_pid} = Supervisor.start_link([spec], strategy: :one_for_one)
    assert Process.alive?(parent_pid)
    [{PoolSup, pool_pid, :supervisor, [PoolSup]}] = Supervisor.which_children(parent_pid)
    assert Process.alive?(pool_pid)
    child_pids = Supervisor.which_children(pool_pid) |> Enum.map(fn {_, pid, _, _} -> pid end)
    assert length(child_pids) == 3
    assert Enum.all?(child_pids, &Process.alive?/1)

    Supervisor.stop(parent_pid)
    refute Process.alive?(parent_pid)
    refute Process.alive?(pool_pid)
    refute Enum.any?(child_pids, &Process.alive?/1)
  end

  test "should not be affected when other linked process dies" do
    {:ok, pool_pid} = PoolSup.start_link(W, [], 3)
    linked_pid = spawn(fn ->
      Process.link(pool_pid)
      :timer.sleep(10_000)
    end)
    state_before = :sys.get_state(pool_pid)
    Process.exit(linked_pid, :shutdown)
    assert :sys.get_state(pool_pid) == state_before
  end

  #
  # property-based tests
  #
  @max_capacity 10

  def initial_state do
    %{capacity: nil, pid: nil, checked_out: []}
  end

  def command(state) do
    case state[:pid] do
      nil ->
        {:call, __MODULE__, :start_pool_sup, [int(0, @max_capacity)]}
      pid ->
        [
          [
            {:call, PoolSup   , :checkout, [pid]},
            {:call, __MODULE__, :try_checkout_and_kill_running_worker, [pid]},
            {:call, PoolSup   , :change_capacity, [pid, int(0, @max_capacity)]},
          ],
          case state[:checked_out] do
            []       -> []
            children -> [
              {:call, PoolSup   , :checkin, [pid, :triq_dom.elements(children)]},
              {:call, __MODULE__, :checkin_and_kill_idle_worker, [pid, :triq_dom.elements(children)]},
            ]
          end,
        ]
        |> List.flatten
        |> :triq_dom.oneof
    end
  end

  def start_pool_sup(capacity) do
    {:ok, pid} = PoolSup.start_link(W, [], capacity, [name: __MODULE__])
    pid
  end

  def try_checkout_and_kill_running_worker(pid) do
    case PoolSup.checkout(pid) do
      nil   -> :ok
      child -> kill_child(child)
    end
  end

  def checkin_and_kill_idle_worker(pid, child) do
    PoolSup.checkin(pid, child)
    kill_child(child)
  end

  defp kill_child(child) do
    f = Enum.random([
      fn -> Process.exit(child, :shutdown) end,
      fn -> Process.exit(child, :kill    ) end,
      fn -> GenServer.stop(child, :normal  ) end,
      fn -> GenServer.stop(child, :shutdown) end,
      # fn -> GenServer.stop(child, :kill    ) end, # This line is disabled just because it generates noisy error logs in test output
    ])
    try do
      f.()
    catch
      :exit, _ -> :ok # child is doubly killed (when decreasing capacity in PoolSup and here)
    end
    :timer.sleep(1) # necessary for the pool process to handle EXIT message prior to the next test step
  end

  def precondition(state, {:call, _, :start_pool_sup, _}) do
    state[:pid] == nil
  end
  def precondition(state, _cmd) do
    state[:pid] != nil
  end

  def postcondition(_state, {:call, __MODULE__, :start_pool_sup, [capacity]}, _ret) do
    invariance_hold?(capacity)
  end
  def postcondition(_state, {:call, PoolSup, :change_capacity, [_, capacity]}, _ret) do
    invariance_hold?(capacity)
  end
  def postcondition(state, _cmd, _ret) do
    invariance_hold?(state[:capacity])
  end

  def next_state(state, v, {:call, __MODULE__, :start_pool_sup, [capacity]}) do
    %{state | capacity: capacity, pid: v}
  end
  def next_state(state, _v, {:call, PoolSup, :change_capacity, [_, capacity]}) do
    %{state | capacity: capacity}
  end
  def next_state(state, v, {:call, PoolSup, :checkout, _}) do
    if length(state[:checked_out]) < state[:capacity] do
      %{state | checked_out: [v | state[:checked_out]]}
    else
      state
    end
  end
  def next_state(state, _v, {:call, PoolSup, :checkin, [_, target]}) do
    %{state | checked_out: List.delete(state[:checked_out], target)}
  end
  def next_state(state, _v, {:call, __MODULE__, :checkin_and_kill_idle_worker, [_, target]}) do
    %{state | checked_out: List.delete(state[:checked_out], target)}
  end
  def next_state(state, _v, _cmd) do
    state
  end

  defp invariance_hold?(capacity) do
    case Process.whereis(__MODULE__) do
      nil -> true
      pid ->
        {:state, all, working, available, to_decrease, sup_state} = :sys.get_state(pid)
        Enum.all?([
          map_size(all) - to_decrease == capacity,
          data_type_correct?(all, working, available, to_decrease),
          all_corresponds_to_child_pids?(all, sup_state),
          union_of_working_and_available_equals_to_all?(all, working, available),
        ])
    end
  end

  defp data_type_correct?(all, working, available, to_decrease) do
    all_pid? = [Map.keys(all), Map.keys(working), available] |> List.flatten |> Enum.all?(&is_pid/1)
    all_pid? && is_integer(to_decrease) && to_decrease >= 0
  end

  defp all_corresponds_to_child_pids?(all, sup_state) do
    {:reply, r, _} = :supervisor.handle_call(:which_children, self, sup_state)
    sup_child_pids = Enum.into(r, MapSet.new, fn {_, pid, _, _} -> pid end)
    all_child_pids = Map.keys(all) |> Enum.into(MapSet.new)
    all_child_pids == sup_child_pids
  end

  defp union_of_working_and_available_equals_to_all?(all, working, available) do
    Enum.into(available, working, fn pid -> {pid, true} end) == all
  end

  property :internal_state_invariance do
    for_all cmds in :triq_statem.commands(__MODULE__) do
      {_, _, :ok} = :triq_statem.run_commands(__MODULE__, cmds)
      Supervisor.stop(__MODULE__)
      true
    end
  end
end
