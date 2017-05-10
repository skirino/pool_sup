use Croma

defmodule PoolSup.PidRefSet do
  @moduledoc false
  @type t :: {%{pid => reference}, %{reference => pid}}

  defun new() :: t, do: {%{}, %{}}

  defun size({p2r, _} :: t) :: non_neg_integer, do: map_size(p2r)

  defun member_pid?({p2r, _} :: t, pid :: pid) :: boolean, do: Map.has_key?(p2r, pid)

  defun get_pid_by_ref({_, r2p} :: t, ref :: reference) :: nil | pid, do: Map.get(r2p, ref)

  defun put({p2r, r2p} :: t, pid :: pid, ref :: reference) :: t do
    # Assuming that same `ref` is never passed to this function (although same `pid` can be reused);
    # we don't have to  delete entry in `p2r`.
    r2p2 =
      case Map.get(p2r, pid) do
        nil -> r2p
        r   -> Map.delete(r2p, r)
      end
    {Map.put(p2r, pid, ref), Map.put(r2p2, ref, pid)}
  end

  defun delete_by_pid({p2r, r2p} = t :: t, pid :: pid) :: t do
    case Map.pop(p2r, pid) do
      {nil, _   } -> t
      {ref, p2r2} -> {p2r2, Map.delete(r2p, ref)}
    end
  end
end