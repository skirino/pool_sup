use Croma

defmodule PoolSup.PidSet do
  @moduledoc false
  @type t :: %{pid => true}
  defun new()                         :: t      , do: %{}
  defun member?(set :: t, pid :: pid) :: boolean, do: Map.has_key?(set, pid)
  defun put(set :: t, pid :: pid)     :: t      , do: Map.put(set, pid, true)
  defun delete(set :: t, pid :: pid)  :: t      , do: Map.delete(set, pid)
  defun to_list(set :: t)             :: [pid]  , do: Map.keys(set)
end
