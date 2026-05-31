defmodule Tank.Runtime.Limits do
  @moduledoc false

  # Applies a container's cgroup v2 resource limits (memory / pids / cpu) at the
  # checkpoint and tears the cgroup down on exit. No limits => no cgroup created.
  # Per-container cgroups live under /sys/fs/cgroup/tank/<name>.

  alias Linx.Cgroup

  @root "/sys/fs/cgroup/tank"

  @doc """
  Apply `limits` to process `pid`, in a cgroup named `name`. Returns
  `{:ok, cgroup_path | nil}` (nil when there are no limits).
  """
  @spec apply(String.t(), pos_integer(), map()) :: {:ok, Path.t() | nil} | {:error, term()}
  def apply(_name, _pid, limits) when map_size(limits) == 0, do: {:ok, nil}

  def apply(name, pid, limits) do
    with {:ok, _} <- Cgroup.create(@root),
         :ok <- enable(@root, controllers(limits)),
         {:ok, cgroup} <- Cgroup.create(Path.join(@root, name)),
         :ok <- set(cgroup, limits),
         :ok <- Cgroup.add_process(cgroup, pid) do
      {:ok, cgroup}
    end
  end

  @doc "Remove the cgroup (no-op when none was created). The /tank root is left in place."
  @spec remove(Path.t() | nil) :: :ok
  def remove(nil), do: :ok

  # rmdir EBUSY's until the just-killed workload is fully reaped out of the
  # cgroup, so retry briefly. (~150ms cap.)
  def remove(cgroup), do: remove(cgroup, 15)

  defp remove(cgroup, 0) do
    _ = Cgroup.destroy(cgroup)
    :ok
  end

  defp remove(cgroup, attempts) do
    case Cgroup.destroy(cgroup) do
      :ok ->
        :ok

      {:error, _} ->
        Process.sleep(10)
        remove(cgroup, attempts - 1)
    end
  end

  defp controllers(limits), do: limits |> Map.keys() |> Enum.map(&controller/1) |> Enum.uniq()

  defp controller(:memory), do: :memory
  defp controller(:pids), do: :pids
  defp controller(:cpu), do: :cpu

  defp enable(root, controllers) do
    case Cgroup.enable_controllers(root, controllers) do
      :ok -> :ok
      {:partial, failures} -> {:error, {:enable_controllers, failures}}
    end
  end

  defp set(cgroup, limits) do
    Enum.reduce_while(limits, :ok, fn {key, value}, :ok ->
      case set_one(cgroup, key, value) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp set_one(cgroup, :memory, bytes), do: Cgroup.set_memory_max(cgroup, bytes)
  defp set_one(cgroup, :pids, n), do: Cgroup.set_pids_max(cgroup, n)
  defp set_one(cgroup, :cpu, quota_period), do: Cgroup.set_cpu_max(cgroup, quota_period)
end
