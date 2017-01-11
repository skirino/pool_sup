defmodule PoolSup.MultiTest do
  use Croma.TestCase
  import CustomSupTest

  @multi_id "some_pool_multi_id"

  defp with_multi(n_pools \\ 3, reserved \\ 4, ondemand \\ 1, f) do
    table_id = :ets.new(:pool_sup_multi, [:set, :public, {:read_concurrency, true}])
    try do
      {:ok, pid} = Multi.start_link(table_id, @multi_id, n_pools, W, [], reserved, ondemand)
      f.(table_id, pid)
      shutdown_pool_multi(pid, table_id)
    after
      :ets.delete(table_id)
    end
  end

  defp shutdown_pool_multi(pid, table_id) do
    children = child_pids(pid)
    grand_children = Enum.flat_map(children, &child_pids/1)
    all_decendants = children ++ grand_children
    Supervisor.stop(pid)
    :timer.sleep(1)
    refute Process.alive?(pid)
    refute Enum.any?(all_decendants, &Process.alive?/1)
    assert :ets.lookup(table_id, @multi_id) == []
  end

  defp child_pids(pid) do
    Supervisor.which_children(pid) |> Enum.map(fn {_, p, _, _} -> p end)
  end

  test "should register name specified by :name option" do
    table_id = :ets.new(:pool_sup_multi, [:set, :public, {:read_concurrency, true}])
    {:ok, pid} = Multi.start_link(table_id, @multi_id, 2, W, [], 1, 0, [name: :registered_name])
    assert Process.whereis(:registered_name) == pid
  end

  test "should behave as an ordinary supervisor" do
    with_multi(fn(_table_id, pid) ->
      assert_which_children(pid, 3)
    end)
  end

  test "should return error for start_child, terminate_child, restart_child, delete_child" do
    with_multi(fn(_table_id, pid) ->
      assert_returns_error_for_prohibited_functions(pid)
    end)
  end

  test "should die when parent process dies" do
    table_id = :ets.new(:pool_sup_multi, [:set, :public, {:read_concurrency, true}])
    spec = Supervisor.Spec.supervisor(Multi, [table_id, @multi_id, 3, W, [], 4, 1])
    assert_dies_on_parent_process_dies(spec, 3)
  end

  test "should not be affected when other linked process dies" do
    with_multi(fn(_table_id, pid) ->
      assert_not_affected_when_non_child_linked_process_dies(pid)
    end)
  end

  test "should not be affected by info messages" do
    with_multi(fn(_table_id, pid) ->
      assert_not_affected_by_info_messages(pid)
    end)
  end

  test "code_change/3 should return an ok-tuple" do
    with_multi(fn(_table_id, pid) ->
      assert_code_change_returns_an_ok_tuple(Multi, pid)
    end)
  end

  test "should pretend as a supervisor when :sys.get_status/1 is called" do
    with_multi(fn(_table_id, pid) ->
      assert_pretends_as_a_supervisor_on_get_status(pid)
    end)
  end

  test "should appropriately checkout worker using a record in ETS table" do
    with_multi(3, 4, 0, fn(table_id, pid) ->
      children = child_pids(pid)
      grand_children = Enum.flat_map(children, &child_pids/1)

      {pool, worker} = Multi.checkout_nonblocking(table_id, @multi_id)
      assert pool   in children
      assert worker in grand_children
      PoolSup.checkin(pool, worker)

      results = Enum.map(1..1000, fn _ -> Multi.checkout_nonblocking(table_id, @multi_id) end) |> Enum.reject(&is_nil/1)
      assert length(results) == 12
      assert Enum.map(results, fn {p, _} -> p end) |> Enum.sort == List.duplicate(children, 4) |> List.flatten |> Enum.sort
      assert Enum.map(results, fn {_, w} -> w end) |> Enum.sort == Enum.sort(grand_children)
    end)
  end

  test "transaction/4 should correctly checkin child pid" do
    with_multi(1, 1, 0, fn(table_id, _pid) ->
      ensure_child_not_in_use = fn ->
        {pool, worker} = Multi.checkout(table_id, @multi_id) # block if something is wrong
        PoolSup.checkin(pool, worker)
      end

      ensure_child_not_in_use.()
      assert Multi.transaction(table_id, @multi_id, fn _ -> :ok end) == :ok
      ensure_child_not_in_use.()
      catch_error Multi.transaction(table_id, @multi_id, fn _ -> raise "foo" end)
      ensure_child_not_in_use.()
      catch_throw Multi.transaction(table_id, @multi_id, fn _ -> throw "bar" end)
      ensure_child_not_in_use.()
      catch_exit Multi.transaction(table_id, @multi_id, fn _ -> exit(:baz) end)
      ensure_child_not_in_use.()
    end)
  end

  test "transaction/4 should correctly link the checked-out process so that termination of caller also terminates the worker process" do
    with_multi(1, 1, 0, fn(table_id, _pid) ->
      caller = spawn(fn ->
        Multi.transaction(table_id, @multi_id, fn _ -> :timer.sleep(10_000) end)
      end)
      :timer.sleep(1)
      Process.exit(caller, :kill)
      {pool, worker} = Multi.checkout(table_id, @multi_id) # block if something is wrong
      PoolSup.checkin(pool, worker)
    end)
  end

  test "should correctly reset capacity of child pools" do
    with_multi(2, 1, 0, fn(_table_id, pid) ->
      [pool1, pool2] = child_pids(pid)
      assert PoolSup.status(pool1) == %{reserved: 1, ondemand: 0, children: 1, available: 1, working: 0}
      assert PoolSup.status(pool2) == %{reserved: 1, ondemand: 0, children: 1, available: 1, working: 0}
      Multi.change_configuration(pid, nil, 2, 1)
      :timer.sleep(1)
      assert PoolSup.status(pool1) == %{reserved: 2, ondemand: 1, children: 2, available: 2, working: 0}
      assert PoolSup.status(pool2) == %{reserved: 2, ondemand: 1, children: 2, available: 2, working: 0}
    end)
  end

  test "should spawn pools; gracefully shutdown unnecessary pool" do
    with_multi(1, 1, 0, fn(table_id, pid) ->
      assert length(child_pids(pid)) == 1
      Multi.change_configuration(pid, 1, nil, nil)
      assert length(child_pids(pid)) == 1

      Multi.change_configuration(pid, 2, 0, 1)
      :timer.sleep(1)
      [pool1, pool2] = child_pids(pid) |> Enum.sort
      assert :ets.lookup_element(table_id, @multi_id, 2) |> Tuple.to_list |> Enum.sort == [pool1, pool2]
      assert PoolSup.status(pool1) == %{reserved: 0, ondemand: 1, children: 0, available: 0, working: 0}
      assert PoolSup.status(pool2) == %{reserved: 0, ondemand: 1, children: 0, available: 0, working: 0}
      worker1 = PoolSup.checkout(pool1)
      worker2 = PoolSup.checkout(pool2)

      Multi.change_configuration(pid, 1, nil, nil)
      assert length(child_pids(pid)) == 2
      status1 = PoolSup.status(pool1)
      status2 = PoolSup.status(pool2)
      assert Enum.sort([status1[:ondemand], status2[:ondemand]]) == [0, 1]

      :timer.sleep(15)                    # Wait for polling of progress check
      assert length(child_pids(pid)) == 2 # Still a worker in the target pool is in-use

      PoolSup.checkin(pool1, worker1)
      PoolSup.checkin(pool2, worker2)
      :timer.sleep(15)                    # Wait for polling of progress check
      [pool3] = child_pids(pid)           # Finally the pool is terminated
      assert :ets.lookup_element(table_id, @multi_id, 2) == {pool3}
    end)
  end

  test "checkout/3 should retry and keep working during pool termination" do
    # Note that this test case is not deterministic;
    # this triggers client retries for around 50% of the time (in the current development environment).
    with_multi(1, 1, 0, fn(table_id, pid) ->
      this_pid = self()
      spawn_link(fn ->
        Enum.each(1..500000, fn _ ->
          {pool, worker} = Multi.checkout(table_id, @multi_id)
          assert is_pid(worker)
          PoolSup.checkin(pool, worker)
        end)
        send(this_pid, :finished)
      end)
      Enum.each(1..500, fn i ->
        Multi.change_configuration(pid, rem(i, 2) * 100 + 1, nil, nil)
        :timer.sleep(5)
      end)
      receive do
        :finished -> :ok
      end
    end)
  end

  test "should handle death of working pool" do
    with_multi(2, 1, 0, fn(table_id, pid) ->
      [pool1, pool2] = child_pids(pid) |> Enum.sort
      assert :ets.lookup_element(table_id, @multi_id, 2) |> Tuple.to_list |> Enum.sort == [pool1, pool2]
      Supervisor.stop(pool1)
      Supervisor.stop(pool2)
      :timer.sleep(10)

      child_pids(pid)
      [pool3, pool4] = child_pids(pid) |> Enum.sort
      refute pool1 in [pool3, pool4]
      assert :ets.lookup_element(table_id, @multi_id, 2) |> Tuple.to_list |> Enum.sort == [pool3, pool4]
    end)
  end

  test "should handle death of pool that is being terminated" do
    with_multi(2, 1, 0, fn(table_id, pid) ->
      [pool1, pool2] = child_pids(pid) |> Enum.sort
      assert :ets.lookup_element(table_id, @multi_id, 2) |> Tuple.to_list |> Enum.sort == [pool1, pool2]
      worker1 = PoolSup.checkout(pool1)
      worker2 = PoolSup.checkout(pool2)

      Multi.change_configuration(pid, 1, nil, nil)
      :timer.sleep(1)
      {pool_to_keep} = :ets.lookup_element(table_id, @multi_id, 2)
      assert pool_to_keep in [pool1, pool2]
      [pool_to_terminate] = [pool1, pool2] -- [pool_to_keep]
      Process.exit(pool_to_terminate, :kill)
      :timer.sleep(1)

      assert Process.alive?(worker1) != Process.alive?(worker2)
      assert child_pids(pid) == [pool_to_keep]
    end)
  end
end
