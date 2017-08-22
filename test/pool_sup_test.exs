defmodule PoolSupTest do
  use ExUnit.Case
  import CustomSupTest

  defp with_pool(reserved \\ 3, ondemand \\ 0, f) do
    {:ok, pid} = PoolSup.start_link(W, [], reserved, ondemand)
    f.(pid)
    shutdown_pool(pid)
  end

  defp shutdown_pool(pool) do
    childs = Supervisor.which_children(pool) |> Enum.map(fn {_, pid, _, _} -> pid end)
    {:links, linked_pids} = Process.info(pool, :links)
    assert Enum.sort(linked_pids) == Enum.sort([self() | childs])
    Supervisor.stop(pool)
    :timer.sleep(1)
    refute Process.alive?(pool)
    refute Enum.any?(childs, &Process.alive?/1)
  end

  test "should register name specified by :name option" do
    {:ok, pid} = PoolSup.start_link(W, [], 3, 0, [name: :registered_name])
    assert Process.whereis(:registered_name) == pid
  end

  test "should behave as an ordinary supervisor" do
    with_pool(fn pid ->
      assert_which_children(pid, 3)
    end)
  end

  test "should return error for start_child, terminate_child, restart_child, delete_child" do
    with_pool(fn pid ->
      assert_returns_error_for_prohibited_functions(pid)
    end)
  end

  test "should die when parent process dies" do
    spec = Supervisor.Spec.supervisor(PoolSup, [W, [], 3, 0])
    assert_dies_on_parent_process_dies(spec, 3)
  end

  test "should not be affected when other linked process dies" do
    with_pool(fn pid ->
      assert_not_affected_when_non_child_linked_process_dies(pid)
    end)
  end

  test "should not be affected by info messages" do
    with_pool(fn pid ->
      assert_not_affected_by_info_messages(pid)
    end)
  end

  test "code_change/3 should return an ok-tuple" do
    with_pool(fn pid ->
      assert_code_change_returns_an_ok_tuple(PoolSup, pid)
    end)
  end

  test "should pretend as a supervisor when :sys.get_status/1 is called" do
    with_pool(fn pid ->
      assert_pretends_as_a_supervisor_on_get_status(pid)
    end)
  end

  test "should checkout/checkin children" do
    with_pool(fn pid ->
      {:state, _, _, _, _, _, children, _, _, _} = :sys.get_state(pid)
      [child1, _child2, _child3] = children
      assert Enum.all?(children, &Process.alive?/1)

      # checkin not-working pid => no effect
      assert PoolSup.status(pid) == %{reserved: 3, ondemand: 0, children: 3, available: 3, working: 0}
      PoolSup.checkin(pid, self())
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

      current_test_pid = self()
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
      {:state, a, b, c, d, e, f, {_waiting_queue, waiting_map}, _, _} = :sys.get_state(pid)
      catch_exit PoolSup.checkout(pid, 10)
      {:state, ^a, ^b, ^c, ^d, ^e, ^f, {_, ^waiting_map}, _, _} = :sys.get_state(pid)

      # waiting clients should receive pids when available
      PoolSup.checkin(pid, worker2)
      assert_receive(^worker2, 10)
      refute Process.alive?(checkout_pid1)

      Process.exit(worker3, :shutdown)
      receive do
        newly_spawned_worker_pid -> refute newly_spawned_worker_pid in [worker1, worker2, worker3]
      end
      refute Process.alive?(checkout_pid2)
    end)
  end

  test "timeout in blocking checkout with reply should not leak any process" do
    with_pool(fn pid ->
      # On rare occasion checkout with timeout=0 succeeds; we try 5 times to make it exit
      catch_exit Enum.each(1..5, fn _ -> PoolSup.checkout(pid, 0) end)
      assert_receive({r, p} when is_reference(r) and is_pid(p))
      assert PoolSup.status(pid)[:working] == 0
    end)
  end

  test "transaction/3 should correctly checkin child pid" do
    with_pool(1, 0, fn pid ->
      ensure_child_not_in_use = fn ->
        child = PoolSup.checkout(pid) # block if something is wrong
        PoolSup.checkin(pid, child)
      end

      ensure_child_not_in_use.()
      assert PoolSup.transaction(pid, fn _ -> :foo end) == :foo
      ensure_child_not_in_use.()
      catch_error PoolSup.transaction(pid, fn _ -> raise "foo" end)
      ensure_child_not_in_use.()
      catch_throw PoolSup.transaction(pid, fn _ -> throw "bar" end)
      ensure_child_not_in_use.()
      catch_exit PoolSup.transaction(pid, fn _ -> exit(:baz) end)
      ensure_child_not_in_use.()
    end)
  end

  test "transaction/3 should correctly link the checked-out process so that termination of caller also terminates the worker process" do
    with_pool(1, 0, fn pid ->
      caller = spawn(fn ->
        PoolSup.transaction(pid, fn _ -> :timer.sleep(10_000) end)
      end)
      :timer.sleep(10)
      Process.exit(caller, :kill)
      child = PoolSup.checkout(pid) # block if something is wrong
      PoolSup.checkin(pid, child)
    end)
  end

  test "killing worker in transaction/3 while a client is waiting should not result in reply of dead worker pid" do
    with_pool(2, 0, fn pid ->
      [
        spawn(fn -> PoolSup.transaction(pid, fn w -> GenServer.stop(w)      end) end),
        spawn(fn -> PoolSup.transaction(pid, fn w -> Process.exit(w, :kill) end) end),
      ]
      |> Enum.each(fn p ->
        mref = Process.monitor(p)
        assert_receive({:DOWN, ^mref, :process, ^p, _reason})
      end)
      assert PoolSup.status(pid) == %{reserved: 2, ondemand: 0, children: 2, working: 0, available: 2}
    end)
  end

  test "should spawn ondemand processes when no available worker exists" do
    with_pool(1, 1, fn pid ->
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
    end)
  end

  test "invariants should hold on every step of randomly generated sequence of operations" do
    Enum.each(1..30, fn _ ->
      initial_reserved = pick_capacity_initial()
      initial_ondemand = pick_capacity_initial()
      with_pool(initial_reserved, initial_ondemand, fn pid ->
        initial_context = initial_context(pid, initial_reserved, initial_ondemand)
        assert_invariants_hold(pid, initial_context, nil)
        Enum.reduce(1..100, initial_context, fn(_, context) ->
          state_before = :sys.get_state(pid)
          new_context = run_cmd(context)
          assert_invariants_hold(pid, new_context, state_before)
          new_context
        end)
      end)
      IO.write(IO.ANSI.green() <> "." <> IO.ANSI.reset())
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
      cmd_checkout_timeout:     [],
      cmd_checkin:              [],
      cmd_change_capacity:      [pick_capacity(), pick_capacity()],
      cmd_kill_running_worker:  [],
      cmd_kill_idle_worker:     [],
      cmd_kill_waiting_client:  [],
    ])
  end

  defp run_cmd(context) do
    {fname, args} = cmd = pick_cmd()
    context2 = apply(__MODULE__, fname, [context | args])
    %{context2 | cmds: [cmd | context[:cmds]]}
  end

  defp assert_invariants_hold(pid, context, state_before) do
    {:state, sup_state, reserved, ondemand, all, working, available, waiting, _, _} = state_after = :sys.get_state(pid)
    try do
      assert reserved == context[:reserved]
      assert map_size(all) >= reserved
      assert data_type_correct?(all, working, available, waiting)
      assert all_corresponds_to_child_pids?(all, sup_state)
      assert union_of_working_and_available_equals_to_all?(all, working, available)
      assert is_working_equal_to_checked_out_in_context?(working, context[:checked_out])
      assert is_all_processes_count_equal_to_reserved_when_any_child_available?(reserved, all, available)
      assert cancel_refs_in_working_and_client_queue_disjoint?(working, waiting)
      waiting_pids = waiting_pids_from_client_queue(waiting)
      assert is_waiting_queue_empty_when_any_child_available?(available, waiting_pids)
      assert is_waiting_queue_empty_when_ondemand_child_available?(reserved, ondemand, all, waiting_pids)
      assert is_waiting_queue_equal_to_client_queue_in_context?(waiting_pids, context[:waiting])
    rescue
      e ->
        commands_so_far = Enum.reverse(context[:cmds])
        IO.puts "commands executed so far = #{inspect(commands_so_far, pretty: true)}"
        IO.inspect(state_before, pretty: true)
        IO.inspect(state_after , pretty: true)
        raise e
    end
  end

  defp data_type_correct?(all, {working1, working2}, available, {waiting_queue, waiting_map}) do
    waiting_queue_list = :queue.to_list(waiting_queue)
    [
      [Map.keys(all), Map.keys(working1), available] |> List.flatten() |> Enum.all?(&is_pid/1),
      Map.values(working1) |> Enum.all?(fn {ref, term} -> is_reference(ref) and is_integer(term) end),
      Enum.all?(waiting_queue_list, fn {{pid, ref}, cref} -> is_pid(pid) and is_reference(ref) and is_reference(cref) end),
      Enum.all?(waiting_map, fn {pid, {cref, mref}} -> is_pid(pid) and is_reference(cref) and is_reference(mref) end),
      Map.new(working1, fn {pid, {ref, _}} -> {pid, ref} end) == Map.new(working2, fn {ref, pid} -> {pid, ref} end),
      MapSet.subset?(MapSet.new(waiting_map, fn {pid, _} -> pid end), MapSet.new(waiting_queue_list, fn {{pid, _}, _} -> pid end)),
    ]
    |> Enum.all?()
  end

  defp all_corresponds_to_child_pids?(all, sup_state) do
    {:reply, r, _} = :supervisor.handle_call(:which_children, self(), sup_state)
    sup_child_pids = MapSet.new(r, fn {_, pid, _, _} -> pid end)
    all_child_pids = Map.keys(all) |> MapSet.new()
    all_child_pids == sup_child_pids
  end

  defp union_of_working_and_available_equals_to_all?(all, {working, _}, available) do
    Enum.sort(available ++ Map.keys(working)) == Enum.sort(Map.keys(all))
  end

  defp is_working_equal_to_checked_out_in_context?({working, _}, checked_out) do
    Enum.sort(Map.keys(working)) == Enum.sort(checked_out)
  end

  defp is_all_processes_count_equal_to_reserved_when_any_child_available?(reserved, all, available) do
    map_size(all) == reserved or Enum.empty?(available)
  end

  defp cancel_refs_in_working_and_client_queue_disjoint?({m1, _}, {_, m2}) do
    s1 = MapSet.new(Map.values(m1))
    s2 = MapSet.new(m2, fn {_pid, {cancel_ref, _monitor_ref}} -> cancel_ref end)
    MapSet.disjoint?(s1, s2)
  end

  defp waiting_pids_from_client_queue({waiting_queue, waiting_map}) do
    :queue.to_list(waiting_queue)
    |> Enum.map(fn {{pid, _}, cref} ->
      case waiting_map[pid] do
        {^cref, _mref} -> pid
        _              -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp is_waiting_queue_empty_when_any_child_available?(available, waiting_pids) do
    Enum.empty?(available) or Enum.empty?(waiting_pids)
  end

  defp is_waiting_queue_empty_when_ondemand_child_available?(reserved, ondemand, all, waiting_pids) do
    map_size(all) >= reserved + ondemand or Enum.empty?(waiting_pids)
  end

  defp is_waiting_queue_equal_to_client_queue_in_context?(waiting_pids, waiting_in_context) do
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
      self_pid = self()
      checkout_pid = spawn(fn ->
        worker_pid = PoolSup.checkout(context[:pid], :infinity)
        send(self_pid, {self(), worker_pid})
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

  def cmd_checkout_timeout(context) do
    try do
      # On rare occastion checkout with timeout=0 succeeds; in that case we treat this cmd as a successful checkout
      pid = PoolSup.checkout(context[:pid], 0)
      assert is_pid(pid)
      %{context | checked_out: [pid | context.checked_out]}
    catch
      :exit, {:timeout, _} ->
        receive do
          {r, p} when is_reference(r) and is_pid(p) -> :ok # reply
        after
          10 -> :ok # pool is full
        end
        context
    end
  end

  def cmd_checkin(context) do
    checked_out = context[:checked_out]
    if Enum.empty?(checked_out) do
      context
    else
      worker = Enum.random(checked_out)
      PoolSup.checkin(context[:pid], worker)
      %{context | checked_out: List.delete(checked_out, worker)} |> receive_msg_from_waiting_processes()
    end
  end

  def cmd_change_capacity(context, new_reserved, new_ondemand) do
    PoolSup.change_capacity(context[:pid], new_reserved, new_ondemand)
    %{context | reserved: new_reserved || context[:reserved], ondemand: new_ondemand || context[:ondemand]}
    |> receive_msg_from_waiting_processes()
  end

  def cmd_kill_running_worker(context) do
    checked_out = context[:checked_out]
    if Enum.empty?(checked_out) do
      context
    else
      worker = Enum.random(checked_out)
      kill_child(worker)
      %{context | checked_out: List.delete(checked_out, worker)} |> receive_msg_from_waiting_processes()
    end
  end

  def cmd_kill_idle_worker(context) do
    {:state, _, _, _, all, {working, _}, _, _, _, _} = :sys.get_state(context[:pid])
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
