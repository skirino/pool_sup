ExUnit.start()

# Suppress supervisor ERROR REPORT about unexpected messages and children's deaths
:error_logger.tty(false)

defmodule W do
  @behaviour PoolSup.Worker
  use GenServer

  def init(args) do
    {:ok, args}
  end

  def child_spec(args) do
    %{
      id:      __MODULE__,
      start:   {__MODULE__, :start_link, args},
      restart: :temporary,
    }
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, {}, [])
  end
end

defmodule CustomSupTest do
  import ExUnit.Assertions

  def assert_which_children(pid, n) do
    children = Supervisor.which_children(pid)
    assert length(children) == n
    assert Supervisor.which_children(pid) == children
    assert Supervisor.count_children(pid)[:active] == n
  end

  def assert_returns_error_for_prohibited_functions(pid) do
    {_, child, _, _} = Supervisor.which_children(pid) |> hd
    assert Supervisor.start_child(pid, [])        == {:error, :pool_sup}
    assert Supervisor.terminate_child(pid, child) == {:error, :simple_one_for_one}
    assert Supervisor.restart_child(pid, :child)  == {:error, :simple_one_for_one}
    assert Supervisor.delete_child(pid, :child)   == {:error, :simple_one_for_one}
  end

  def assert_dies_on_parent_process_dies(spec, n_children) do
    {:ok, parent_pid} = Supervisor.start_link([spec], strategy: :one_for_one)
    assert Process.alive?(parent_pid)
    [{mod, pid, :supervisor, [mod]}] = Supervisor.which_children(parent_pid)
    assert Process.alive?(pid)
    child_pids = Supervisor.which_children(pid) |> Enum.map(fn {_, p, _, _} -> p end)
    assert length(child_pids) == n_children
    assert Enum.all?(child_pids, &Process.alive?/1)

    Supervisor.stop(parent_pid)
    :timer.sleep(1)
    refute Process.alive?(parent_pid)
    refute Process.alive?(pid)
    refute Enum.any?(child_pids, &Process.alive?/1)
  end

  def assert_not_affected_when_non_child_linked_process_dies(pid) do
    linked_pid = spawn(fn ->
      Process.link(pid)
      :timer.sleep(10_000)
    end)
    state_before = :sys.get_state(pid)
    Process.exit(linked_pid, :shutdown)
    assert :sys.get_state(pid) == state_before
  end

  def assert_not_affected_by_info_messages(pid) do
    state = :sys.get_state(pid)
    send(pid, :arbitrary_message)
    assert :sys.get_state(pid) == state

    temp_pid = spawn(fn -> :ok end)
    mref = Process.monitor(temp_pid)
    send(pid, {:DOWN, mref, :process, temp_pid, :shutdown})
    assert :sys.get_state(pid) == state
  end

  def assert_code_change_returns_an_ok_tuple(mod, pid) do
    state = :sys.get_state(pid)
    assert match?({:ok, _}, mod.code_change('0.1.2', state, []))
  end

  def assert_pretends_as_a_supervisor_on_get_status(pid) do
    sup_state = :sys.get_state(pid) |> elem(1)
    {:status, _pid, {:module, _mod}, [_pdict, _sysstate, _parent, _dbg, misc]} = :sys.get_status(pid)
    [_header, _data, {:data, [{'State', state_from_get_status}]}] = misc
    assert state_from_get_status == sup_state

    # supervisor:get_callback_module/1 (since Erlang/OTP 18.3), which internally uses sys:get_status/1
    if otp_version() >= {18, 3, 0} do
      assert :supervisor.get_callback_module(pid) == PoolSup.Callback
    end
  end

  defp otp_version do
    otp_version_path = Path.join([:code.root_dir, "releases", :erlang.system_info(:otp_release), "OTP_VERSION"])
    case File.read!(otp_version_path) |> String.trim_trailing() |> String.split(".") |> Enum.map(&String.to_integer/1) do
      [major, minor]        -> {major, minor, 0    }
      [major, minor, patch] -> {major, minor, patch}
    end
  end
end
