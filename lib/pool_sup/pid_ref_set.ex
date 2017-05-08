use Croma

defmodule PoolSup.PidRefSet do
  @moduledoc false
  @type t :: {%{pid => reference}, %{reference => pid}}

  defun new() :: t, do: {%{}, %{}}

  defun size({m1, _} :: t) :: non_neg_integer, do: map_size(m1)

  defun member_pid?({m1, _ } :: t, pid :: pid      ) :: boolean, do: Map.has_key?(m1, pid)

  defun put({m1, m2} :: t, pid :: pid, ref :: reference) :: t do
    {Map.put(m1, pid, ref), Map.put(m2, ref, pid)}
  end

  defun delete_by_pid({m1, m2} = t :: t, pid :: pid) :: t do
    case Map.pop(m1, pid) do
      {nil, _} -> t
      {ref, m} -> {m, Map.delete(m2, ref)}
    end
  end
end
