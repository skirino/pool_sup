use Croma

defmodule PoolSup.ClientQueue do
  @moduledoc false

  @typep cancel_ref  :: reference
  @typep monitor_ref :: reference

  @type t :: {:queue.queue({GenServer.from, cancel_ref}), %{pid => {cancel_ref, monitor_ref}}}

  defun new() :: t, do: {:queue.new(), %{}}

  defun enqueue_and_monitor({q1, m1} :: t, {pid, _} = from :: GenServer.from, cancel_ref :: cancel_ref) :: t do
    q2 = :queue.in({from, cancel_ref}, q1)
    monitor_ref =
      case Map.get(m1, pid) do
        nil                                -> Process.monitor(pid)
        {_old_cancel_ref, old_monitor_ref} -> old_monitor_ref # reuse the already created monitor; the previous entry is cancelled by setting the new `cancel_ref`
      end
    m2 = Map.put(m1, pid, {cancel_ref, monitor_ref})
    {q2, m2}
  end

  defun dequeue_and_demonitor({q1, m1} :: t) :: nil | {GenServer.from, cancel_ref, t} do
    case :queue.out(q1) do
      {:empty                                 , _ } -> nil
      {{:value, {{pid, _} = from, cancel_ref}}, q2} ->
        case Map.pop(m1, pid) do
          {nil, _ } ->
            # the entry has already cancelled; proceed to the next entry
            dequeue_and_demonitor({q2, m1})
          {{^cancel_ref, monitor_ref}, m2} ->
            Process.demonitor(monitor_ref)
            {from, cancel_ref, {q2, m2}}
          {_different_cancel_ref, m2} ->
            # the same client calls blocking checkout more than once; older entry has already been cancelled
            dequeue_and_demonitor({q2, m2})
        end
    end
  end

  defun cancel({q, m1} = t :: t, pid :: pid, cancel_ref_or_nil :: nil | cancel_ref) :: t do
    case Map.pop(m1, pid) do
      {nil                      , _ } -> t
      {{cancel_ref, monitor_ref}, m2} ->
        case cancel_ref_or_nil do
          ^cancel_ref -> Process.demonitor(monitor_ref)
          _           -> :ok
        end
        {q, m2}
    end
  end
end
