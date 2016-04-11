defmodule PoolSupTest do
  use ExUnit.Case
  import CustomSupTest

  defp shutdown_pool(pool) do
    childs = Supervisor.which_children(pool) |> Enum.map(fn {_, pid, _, _} -> pid end)
    Supervisor.stop(pool)
    :timer.sleep(1)
    refute Process.alive?(pool)
    refute Enum.any?(childs, &Process.alive?/1)
  end

  test "should behave as an ordinary supervisor" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, 0, [name: __MODULE__])
    assert_which_children(pid, 3)
    shutdown_pool(pid)
  end

  test "should return error for start_child, terminate_child, restart_child, delete_child" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, 0)
    assert_returns_error_for_prohibited_functions(pid)
    shutdown_pool(pid)
  end

  test "should die when parent process dies" do
    spec = Supervisor.Spec.supervisor(PoolSup, [W, [], 3, 0])
    assert_dies_on_parent_process_dies(spec, 3)
  end

  test "should not be affected when other linked process dies" do
    {:ok, pool_pid} = PoolSup.start_link(W, [], 3, 0)
    assert_not_affected_when_non_child_linked_process_dies(pool_pid)
    shutdown_pool(pool_pid)
  end

  test "should not be affected by info messages" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, 0)
    assert_not_affected_by_info_messages(pid)
    shutdown_pool(pid)
  end

  test "code_change/3 should return an ok-tuple" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, 0)
    assert_code_change_returns_an_ok_tuple(PoolSup, pid)
    shutdown_pool(pid)
  end

  test "should pretend as a supervisor when :sys.get_status/1 is called" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, 0)
    assert_pretends_as_a_supervisor_on_get_status(pid)
    shutdown_pool(pid)
  end

  test "should checkout/checkin children" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, 0)
    {:state, _, _, _, _, _, children, _} = :sys.get_state(pid)
    [child1, _child2, _child3] = children
    assert Enum.all?(children, &Process.alive?/1)

    # checkin not-working pid => no effect
    assert PoolSup.status(pid) == %{reserved: 3, ondemand: 0, children: 3, available: 3, working: 0}
    PoolSup.checkin(pid, self)
    assert PoolSup.status(pid) == %{reserved: 3, ondemand: 0, children: 3, available: 3, working: 0}
    PoolSup.checkin(pid, child1)
    assert PoolSup.status(pid) == %{reserved: 3, ondemand: 0, children: 3, available: 3, working: 0}

    # nonblocking checkout
    worker1 = PoolSup.checkout_nonblocking(pid)
    worker2 = PoolSup.checkout_nonblocking(pid)
    worker3 = PoolSup.checkout_nonblocking(pid)
    assert MapSet.new([worker1, worker2, worker3]) == MapSet.new(children)
    assert PoolSup.checkout_nonblocking(pid) == nil
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

    # `waiting` queue should be restored when blocking checkout failed
    :timer.sleep(1)
    state1 = :sys.get_state(pid)
    catch_exit PoolSup.checkout(pid, 10)
    assert :sys.get_state(pid) == state1

    # waiting clients should receive pids when available
    PoolSup.checkin(pid, worker2)
    assert_receive(worker2, 10)
    refute Process.alive?(checkout_pid1)

    Process.exit(worker3, :shutdown)
    receive do
      newly_spawned_worker_pid -> refute newly_spawned_worker_pid in [worker1, worker2, worker3]
    end
    refute Process.alive?(checkout_pid2)

    shutdown_pool(pid)
  end

  test "transaction/3 should correctly checkin child pid" do
    {:ok, pid} = PoolSup.start_link(W, [], 1, 0)
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

    shutdown_pool(pid)
  end

  test "should spawn ondemand processes when no available worker exists" do
    {:ok, pid} = PoolSup.start_link(W, [], 1, 1)

    assert PoolSup.status(pid) == %{reserved: 1, ondemand: 1, children: 1, working: 0, available: 1}
    w1 = PoolSup.checkout_nonblocking(pid)
    assert is_pid(w1)
    assert PoolSup.status(pid) == %{reserved: 1, ondemand: 1, children: 1, working: 1, available: 0}
    w2 = PoolSup.checkout_nonblocking(pid)
    assert is_pid(w2)
    assert PoolSup.status(pid) == %{reserved: 1, ondemand: 1, children: 2, working: 2, available: 0}
    assert PoolSup.checkout_nonblocking(pid) == nil
    PoolSup.checkin(pid, w1)
    assert PoolSup.status(pid) == %{reserved: 1, ondemand: 1, children: 1, working: 1, available: 0}
    PoolSup.checkin(pid, w2)
    assert PoolSup.status(pid) == %{reserved: 1, ondemand: 1, children: 1, working: 0, available: 1}

    shutdown_pool(pid)
  end

  test "invariance should hold on every step of randomly generated sequence of operations" do
    Enum.each(1..30, fn _ ->
      initial_reserved = pick_capacity_initial
      initial_ondemand = pick_capacity_initial
      {:ok, pid} = PoolSup.start_link(W, [], initial_reserved, initial_ondemand)
      initial_context = initial_context(pid, initial_reserved, initial_ondemand)
      assert_invariance_hold(pid, initial_context, nil)
      Enum.reduce(1..100, initial_context, fn(_, context) ->
        state_before = :sys.get_state(pid)
        new_context = run_cmd(context)
        assert_invariance_hold(pid, new_context, state_before)
        new_context
      end)
      shutdown_pool(pid)
      IO.write(IO.ANSI.green <> "." <> IO.ANSI.reset)
    end)
  end

  defp initial_context(pid, reserved, ondemand) do
    %{pid: pid, reserved: reserved, ondemand: ondemand, checked_out: [], waiting: :queue.new, cmds: [start: [reserved, ondemand]]}
  end

  @capacity_values [0, 1, 2, 3, 5, 10]
  defp pick_capacity_initial, do: Enum.random(@capacity_values)
  defp pick_capacity        , do: Enum.random([nil | @capacity_values])

  defp pick_cmd do
    Enum.random([
      cmd_checkout_nonblocking: [],
      cmd_checkout_or_catch:    [],
      cmd_checkout_wait:        [],
      cmd_checkin:              [],
      cmd_change_capacity:      [pick_capacity, pick_capacity],
      cmd_kill_running_worker:  [],
      cmd_kill_idle_worker:     [],
      cmd_kill_waiting_client:  [],
    ])
  end

  defp run_cmd(context) do
    {fname, args} = cmd = pick_cmd
    context2 = apply(__MODULE__, fname, [context | args])
    %{context2 | cmds: [cmd | context[:cmds]]}
  end

  defp assert_invariance_hold(pid, context, state_before) do
    {:state, sup_state, reserved, ondemand, all, working, available, waiting} = state_after = :sys.get_state(pid)
    try do
      assert reserved == context[:reserved]
      assert map_size(all) >= reserved
      assert data_type_correct?(all, working, available, waiting)
      assert all_corresponds_to_child_pids?(all, sup_state)
      assert union_of_working_and_available_equals_to_all?(all, working, available)
      assert is_working_equal_to_checked_out_in_context?(working, context[:checked_out])
      assert is_all_processes_count_equal_to_reserved_when_any_child_available?(reserved, all, available)
      assert is_waiting_queue_empty_when_any_child_available?(available, waiting)
      assert is_waiting_queue_empty_when_ondemand_child_available?(reserved, ondemand, all, waiting)
      assert is_waiting_queue_equal_to_client_queue_in_context?(waiting, context[:waiting])
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
    all_pairs? = :queue.to_list(waiting) |> Enum.all?(fn {{pid, ref}, mref} -> is_pid(pid) and is_reference(ref) and is_reference(mref) end)
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

  defp is_working_equal_to_checked_out_in_context?(working, checked_out) do
    assert working == Enum.into(checked_out, %{}, fn pid -> {pid, true} end)
  end

  defp is_all_processes_count_equal_to_reserved_when_any_child_available?(reserved, all, available) do
    map_size(all) == reserved or Enum.empty?(available)
  end

  defp is_waiting_queue_empty_when_any_child_available?(available, waiting) do
    Enum.empty?(available) or :queue.is_empty(waiting)
  end

  defp is_waiting_queue_empty_when_ondemand_child_available?(reserved, ondemand, all, waiting) do
    map_size(all) >= reserved + ondemand or :queue.is_empty(waiting)
  end

  defp is_waiting_queue_equal_to_client_queue_in_context?(waiting, waiting_in_context) do
    waiting_pids = :queue.to_list(waiting) |> Enum.map(fn {{pid, _}, _} -> pid end)
    assert waiting_pids == :queue.to_list(waiting_in_context)
  end

  def cmd_checkout_nonblocking(context) do
    checked_out = context[:checked_out]
    pid = PoolSup.checkout_nonblocking(context[:pid])
    if length(checked_out) >= context[:reserved] + context[:ondemand] do
      assert pid == nil
      context
    else
      assert is_pid(pid)
      %{context | checked_out: [pid | checked_out]}
    end
  end

  def cmd_checkout_or_catch(context) do
    checked_out = context[:checked_out]
    if length(checked_out) >= context[:reserved] + context[:ondemand] do
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
    if length(checked_out) >= context[:reserved] + context[:ondemand] do
      self_pid = self
      checkout_pid = spawn(fn ->
        worker_pid = PoolSup.checkout(context[:pid], :infinity)
        send(self_pid, {self, worker_pid})
      end)
      assert Process.alive?(checkout_pid)
      :timer.sleep(1) # Gives the newly-spawned process a timeslice
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

  def cmd_change_capacity(context, new_reserved, new_ondemand) do
    PoolSup.change_capacity(context[:pid], new_reserved, new_ondemand)
    %{context | reserved: new_reserved || context[:reserved], ondemand: new_ondemand || context[:ondemand]}
    |> receive_msg_from_waiting_processes
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
    {:state, _, _, _, all, working, _, _} = :sys.get_state(context[:pid])
    idle_workers = Map.keys(all) -- Map.keys(working)
    if !Enum.empty?(idle_workers) do
      worker = Enum.random(idle_workers)
      kill_child(worker)
    end
    context
  end

  def cmd_kill_waiting_client(context) do
    waiting = :queue.to_list(context[:waiting])
    if Enum.empty?(waiting) do
      context
    else
      client_pid = Enum.random(waiting)
      Process.exit(client_pid, :kill)
      :timer.sleep(1)
      new_waiting = :queue.filter(&(&1 != client_pid), context[:waiting])
      %{context | waiting: new_waiting}
    end
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
end
