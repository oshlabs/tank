defmodule Tank.Runtime.Limits do
  @moduledoc false

  # Applies a container's cgroup v2 resource limits (memory / pids / cpu) at the
  # checkpoint and tears the cgroup down on exit. Per-container cgroups live
  # under /sys/fs/cgroup/tank/<name>, and one is created for EVERY pod — not
  # just limited ones — so Tank.Stats can read cpu/memory/pids accounting
  # regardless of limits. A no-limits pod whose cgroup can't be created
  # (exotic cgroup setups) soft-fails to {:ok, nil}: it runs unaccounted,
  # exactly as it did before stats existed.

  alias Linx.Cgroup

  @root "/sys/fs/cgroup/tank"

  @doc """
  Apply `limits` to process `pid`, in a cgroup named `name`. Returns
  `{:ok, cgroup_path | nil}` (nil when there are no limits).
  """
  @spec apply(String.t(), pos_integer(), map()) :: {:ok, Path.t() | nil} | {:error, term()}
  def apply(name, pid, limits) do
    result =
      with {:ok, _} <- Cgroup.create(@root),
           :ok <- enable(@root, controllers(limits)),
           {:ok, cgroup} <- Cgroup.create(Path.join(@root, name)),
           :ok <- set(cgroup, limits),
           :ok <- Cgroup.add_process(cgroup, pid) do
        {:ok, cgroup}
      end

    case {result, map_size(limits)} do
      {{:ok, _} = ok, _} ->
        ok

      {{:error, reason}, 0} ->
        require Logger

        Logger.warning(
          "Tank.Runtime.Limits[#{name}]: no stats cgroup (#{inspect(reason)}); " <>
            "the pod runs unaccounted"
        )

        {:ok, nil}

      {{:error, _} = err, _} ->
        err
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

  # cpu/memory/pids are always enabled (their .stat/.current files are what
  # Tank.Stats reads); limits can only name the same three today.
  defp controllers(limits),
    do: Enum.uniq([:cpu, :memory, :pids] ++ Enum.map(Map.keys(limits), &controller/1))

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
