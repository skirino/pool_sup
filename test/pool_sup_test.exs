defmodule PoolSupTest do
  use ExUnit.Case

  defmodule W do
    @behaviour PoolSup.Worker
    use GenServer
    def start_link(_) do
      GenServer.start_link(__MODULE__, {}, [])
    end
  end

  test "should behave as an ordinary supervisor" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, [name: __MODULE__])
    children = Supervisor.which_children(pid)
    assert length(children) == 3
    assert Supervisor.which_children(pid) == children
    assert Supervisor.count_children(pid)[:active] == 3
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
    {:state, _, _, _, _, children, _, _} = :sys.get_state(pid)
    [child1, _child2, _child3] = children
    assert Enum.all?(children, &Process.alive?/1)

    # checkin not-working pid => no effect
    assert PoolSup.status(pid) == %{reserved: 3, children: 3, available: 3, working: 0}
    PoolSup.checkin(pid, self)
    assert PoolSup.status(pid) == %{reserved: 3, children: 3, available: 3, working: 0}
    PoolSup.checkin(pid, child1)
    assert PoolSup.status(pid) == %{reserved: 3, children: 3, available: 3, working: 0}

    # nonblocking checkout
    worker1 = PoolSup.checkout_nonblock(pid)
    worker2 = PoolSup.checkout_nonblock(pid)
    worker3 = PoolSup.checkout_nonblock(pid)
    assert MapSet.new([worker1, worker2, worker3]) == MapSet.new(children)
    assert PoolSup.checkout_nonblock(pid) == nil
    PoolSup.checkin(pid, worker1)

    # blocking checkout
    ^worker1 = PoolSup.checkout(pid)
    catch_exit PoolSup.checkout(pid, 10)

    current_test_pid = self
    f = fn ->
      send(current_test_pid, PoolSup.checkout(pid))
    end
    checkout_pid1 = spawn(f)
    :timer.sleep(1)
    checkout_pid2 = spawn(f)
    assert Process.alive?(checkout_pid1)
    assert Process.alive?(checkout_pid2)

    PoolSup.checkin(pid, worker2)
    assert_receive(worker2, 10)
    refute Process.alive?(checkout_pid1)

    Process.exit(worker3, :shutdown)
    receive do
      newly_spawned_worker_pid -> refute newly_spawned_worker_pid in [worker1, worker2, worker3]
    end
    refute Process.alive?(checkout_pid2)

    # cleanup
    Supervisor.stop(pid)
    refute Process.alive?(pid)
    refute Enum.any?(children, &Process.alive?/1)
  end

  test "transaction/3 should correctly checkin child pid" do
    {:ok, pid} = PoolSup.start_link(W, [], 1)
    child_not_in_use? = fn ->
      child = PoolSup.checkout(pid)
      PoolSup.checkin(pid, child)
    end

    assert child_not_in_use?.()
    assert PoolSup.transaction(pid, fn _ -> :ok end) == :ok
    assert child_not_in_use?.()
    catch_error PoolSup.transaction(pid, fn _ -> raise "foo" end)
    assert child_not_in_use?.()
    catch_throw PoolSup.transaction(pid, fn _ -> throw "bar" end)
    assert child_not_in_use?.()
    catch_exit PoolSup.transaction(pid, fn _ -> exit(:baz) end)
    assert child_not_in_use?.()
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

  test "should not be affected by some info messages" do
    {:ok, pid} = PoolSup.start_link(W, [], 3)
    state = :sys.get_state(pid)
    send(pid, :timeout)
    assert :sys.get_state(pid) == state

    mref = Process.monitor(pid)
    send(pid, {:DOWN, mref, :process, self, :shutdown})
    assert :sys.get_state(pid) == state
  end

  test "invariance should hold on every step of randomly generated sequence of operations" do
    Enum.each(1..10, fn _ ->
      initial_reserved = pick_reserved
      {:ok, pid} = PoolSup.start_link(W, [], initial_reserved)
      initial_context = %{reserved: initial_reserved, pid: pid, checked_out: [], waiting: :queue.new, cmds: [start: [initial_reserved]]}
      assert_invariance_hold(pid, initial_context, nil)
      Enum.reduce(1..100, initial_context, fn(_, context) ->
        state_before = :sys.get_state(pid)
        new_context = run_cmd(context)
        assert_invariance_hold(pid, new_context, state_before)
        new_context
      end)
      :ok = Supervisor.stop(pid)
      IO.write(IO.ANSI.green <> "." <> IO.ANSI.reset)
    end)
  end

  @max_reserved 5

  defp pick_reserved do
    :rand.uniform(@max_reserved + 1) - 1
  end

  defp pick_cmd do
    Enum.random([
      cmd_checkout_nonblock:   [],
      cmd_checkout_or_catch:   [],
      cmd_checkout_wait:       [],
      cmd_checkin:             [],
      cmd_change_capacity:     [pick_reserved],
      cmd_kill_running_worker: [],
      cmd_kill_idle_worker:    [],
    ])
  end

  defp run_cmd(context) do
    {fname, args} = cmd = pick_cmd
    context2 = apply(__MODULE__, fname, [context | args])
    %{context2 | cmds: [cmd | context[:cmds]]}
  end

  defp assert_invariance_hold(pid, context, state_before) do
    {:state, reserved, _ondemand, all, working, available, waiting, sup_state} = state_after = :sys.get_state(pid)
    try do
      assert reserved == context[:reserved]
      assert map_size(all) >= reserved
      assert data_type_correct?(all, working, available, waiting)
      assert all_corresponds_to_child_pids?(all, sup_state)
      assert union_of_working_and_available_equals_to_all?(all, working, available)
      assert is_all_processes_count_equal_to_reserved_when_any_child_available?(reserved, all, available)
      assert is_waiting_queue_empty_when_any_child_available?(available, waiting)
    rescue
      e ->
        commands_so_far = Enum.reverse(context[:cmds])
        IO.puts "commands executed so far = #{inspect(commands_so_far, pretty: true)}"
        IO.inspect(state_before, pretty: true)
        IO.inspect(state_after , pretty: true)
        raise e
    end
  end

  defp data_type_correct?(all, working, available, waiting) do
    all_pid? = [Map.keys(all), Map.keys(working), available] |> List.flatten |> Enum.all?(&is_pid/1)
    all_pairs? = :queue.to_list(waiting) |> Enum.all?(fn {pid, ref} -> is_pid(pid) and is_reference(ref) end)
    all_pid? and all_pairs?
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

  defp is_all_processes_count_equal_to_reserved_when_any_child_available?(reserved, all, available) do
    map_size(all) == reserved or Enum.empty?(available)
  end

  defp is_waiting_queue_empty_when_any_child_available?(available, waiting) do
    Enum.empty?(available) or :queue.is_empty(waiting)
  end

  def cmd_checkout_nonblock(context) do
    checked_out = context[:checked_out]
    pid = PoolSup.checkout_nonblock(context[:pid])
    if length(checked_out) >= context[:reserved] do
      assert pid == nil
      context
    else
      assert is_pid(pid)
      %{context | checked_out: [pid | checked_out]}
    end
  end

  def cmd_checkout_or_catch(context) do
    checked_out = context[:checked_out]
    if length(checked_out) >= context[:reserved] do
      catch_exit PoolSup.checkout(context[:pid], 10)
      context
    else
      pid = PoolSup.checkout(context[:pid])
      assert is_pid(pid)
      %{context | checked_out: [pid | checked_out]}
    end
  end

  def cmd_checkout_wait(context) do
    checked_out = context[:checked_out]
    if length(checked_out) >= context[:reserved] do
      self_pid = self
      checkout_pid = spawn(fn ->
        worker_pid = PoolSup.checkout(context[:pid], :infinity)
        send(self_pid, {self, worker_pid})
      end)
      assert Process.alive?(checkout_pid)
      %{context | waiting: :queue.in(checkout_pid, context[:waiting])}
    else
      pid = PoolSup.checkout(context[:pid], 1000)
      assert is_pid(pid)
      %{context | checked_out: [pid | checked_out]}
    end
  end

  def cmd_checkin(context) do
    checked_out = context[:checked_out]
    if Enum.empty?(checked_out) do
      context
    else
      worker = Enum.random(checked_out)
      PoolSup.checkin(context[:pid], worker)
      %{context | checked_out: List.delete(checked_out, worker)} |> receive_msg_from_waiting_processes
    end
  end

  defp receive_msg_from_waiting_processes(context) do
    receive do
      {waiting_pid, checked_out_pid} ->
        new_checked_out = [checked_out_pid | context[:checked_out]]
        new_waiting = :queue.filter(fn w -> w != waiting_pid end, context[:waiting])
        new_context = %{context | checked_out: new_checked_out, waiting: new_waiting}
        receive_msg_from_waiting_processes(new_context)
    after
      10 -> context
    end
  end

  def cmd_change_capacity(context, new_reserved) do
    PoolSup.change_capacity(context[:pid], new_reserved)
    %{context | reserved: new_reserved} |> receive_msg_from_waiting_processes
  end

  def cmd_kill_running_worker(context) do
    checked_out = context[:checked_out]
    if Enum.empty?(checked_out) do
      context
    else
      worker = Enum.random(checked_out)
      kill_child(worker)
      %{context | checked_out: List.delete(checked_out, worker)} |> receive_msg_from_waiting_processes
    end
  end

  def cmd_kill_idle_worker(context) do
    {:state, _, _, all, working, _, _, _} = :sys.get_state(context[:pid])
    idle_workers = Map.keys(all) -- Map.keys(working)
    if !Enum.empty?(idle_workers) do
      worker = Enum.random(idle_workers)
      kill_child(worker)
    end
    context
  end

  defp kill_child(child) do
    f = Enum.random([
      fn -> Process.exit(child, :shutdown) end,
      fn -> Process.exit(child, :kill    ) end,
      fn -> GenServer.stop(child, :normal  ) end,
      fn -> GenServer.stop(child, :shutdown) end,
      fn -> GenServer.stop(child, :kill    ) end,
    ])
    try do
      f.()
    catch
      :exit, _ -> :ok # child is doubly killed (when decreasing capacity in PoolSup and here)
    end
    :timer.sleep(1) # necessary for the pool process to handle EXIT message prior to the next test step
  end
end
