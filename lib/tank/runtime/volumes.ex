defmodule Tank.Runtime.Volumes do
  @moduledoc """
  Resolves a container's `Tank.Mount`s against the pod's `Tank.Volume`s into
  concrete host-side bind sources, creating managed volume directories on the
  way.

  A managed volume lives at `<data_dir>/volumes/<name>` — keyed by volume name
  alone, not by pod, so the same name is stable storage across pod restarts
  and spec changes (delete-and-reapply finds its data again). A `{:host,
  path}` source must already exist: Tank refuses to invent directories
  outside its own data dir (`{:volume_source_missing, …}`).

  Resolution runs at bring-up, host-side, before the workload spawns; the
  actual bind mounts happen later inside the container's mount namespace
  (`Tank.Runtime.Rootfs`).
  """

  alias Tank.{Container, Mount, Pod, Volume}

  @typedoc "A mount ready to actuate: host source dir, in-rootfs path, ro flag."
  @type resolved :: %{source: Path.t(), path: String.t(), read_only: boolean()}

  @doc "Resolve `container`'s mounts against `pod`'s volumes under `data_dir`."
  @spec resolve(Pod.t(), Container.t(), Path.t()) :: {:ok, [resolved()]} | {:error, term()}
  def resolve(%Pod{volumes: volumes}, %Container{mounts: mounts}, data_dir) do
    by_name = Map.new(volumes, &{&1.name, &1})

    mounts
    |> Enum.reduce_while({:ok, []}, fn %Mount{} = mount, {:ok, acc} ->
      case source(by_name[mount.volume], mount, data_dir) do
        {:ok, source} ->
          {:cont, {:ok, [%{source: source, path: mount.path, read_only: mount.read_only} | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      {:error, _} = err -> err
    end
  end

  # Pod.new/1 validates that every mount names a defined volume; stay total
  # anyway for hand-built structs.
  defp source(nil, %Mount{volume: name}, _data_dir), do: {:error, {:unknown_volume, name}}

  defp source(%Volume{source: :managed, name: name}, _mount, data_dir) do
    dir = Path.join([data_dir, "volumes", name])

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, {:volume_mkdir_failed, dir, reason}}
    end
  end

  defp source(%Volume{source: {:host, path}, name: name}, _mount, _data_dir) do
    if File.dir?(path) do
      {:ok, path}
    else
      {:error, {:volume_source_missing, name, path}}
    end
  end
end
