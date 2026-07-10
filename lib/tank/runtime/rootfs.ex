defmodule Tank.Runtime.Rootfs do
  @moduledoc """
  Host-side container rootfs bring-up, run during the `Linx.Process` `:ready`
  checkpoint. Builds the container's filesystem inside its mount namespace and
  pivots into it, leaving the workload ready to `execve`.

  Every step runs in the child's mount namespace via `in: {:pid, host_pid}`.
  The sequence mirrors the proven Linx M2 bring-up:

    1. **make `/` rec-private** — sever mount propagation so nothing leaks back
       to the host (a child's mount ns is a shared peer of the host's).
    2. **bind `rootfs` → `rootfs`, make it private** — `pivot_root` requires the
       new root to be a private mount point.
    3. **`/proc`** — mounted pidns-aware (Linx forks into the container's PID
       namespace, so `/proc` shows the container's pids).
    4. **`/dev`** — a fresh tmpfs with the standard device nodes bind-mounted
       from the host (`mknod` is barred in containers; binds are the way).
    5. **`/sys`** — recursive bind of the host's sysfs.
    6. **volumes** — each resolved `Tank.Mount` bind-mounted at its in-rootfs
       path (read-only ones sealed with a `remount(:ro, :bind)`).
    7. **`pivot_root`** into `rootfs`, then detach the old root.

  All mounts are set up *under* `rootfs` and come along with the pivot.
  """

  alias Linx.Mount
  alias Tank.Runtime.Volumes

  # The device nodes a typical container expects under /dev.
  @device_nodes ~w(null zero full random urandom tty)

  @doc """
  Bring up `rootfs` for the container parked at `host_pid`. On success the
  child's mount namespace has `rootfs` as `/`, with `/proc`, `/dev`, and `/sys`
  populated. Returns the first error encountered.

  `etc_files` is a list of `{host_path, in_rootfs_path}` to bind into the rootfs
  before the pivot — per-pod files (e.g. `/etc/resolv.conf`, `/etc/hosts`) that
  must not mutate the shared, content-addressed image rootfs.

  `volume_mounts` is a list of `t:Tank.Runtime.Volumes.resolved/0` — host
  directories bind-mounted at their in-rootfs paths before the pivot,
  read-only ones sealed with a follow-up `remount(:ro, :bind)`.
  """
  @spec setup(pos_integer(), Path.t(), [{Path.t(), Path.t()}], [Volumes.resolved()]) ::
          :ok | {:error, term()}
  def setup(host_pid, rootfs, etc_files \\ [], volume_mounts \\ [])
      when is_integer(host_pid) and is_binary(rootfs) do
    in_ns = [in: {:pid, host_pid}]

    with :ok <- rec_private(in_ns),
         :ok <- bind_rootfs(rootfs, in_ns),
         :ok <- mount_proc(rootfs, in_ns),
         :ok <- mount_dev(rootfs, in_ns),
         :ok <- mount_sys(rootfs, in_ns),
         :ok <- bind_etc_files(rootfs, etc_files, in_ns),
         :ok <- mount_volumes(rootfs, volume_mounts, in_ns),
         :ok <- pivot(rootfs, in_ns) do
      :ok
    end
  end

  defp rec_private(in_ns), do: Mount.mount("", "/", "", [flags: [:private, :rec]] ++ in_ns)

  defp bind_rootfs(rootfs, in_ns) do
    with :ok <- Mount.bind(rootfs, rootfs, in_ns) do
      Mount.mount("", rootfs, "", [flags: [:private]] ++ in_ns)
    end
  end

  defp mount_proc(rootfs, in_ns) do
    Mount.mount(
      "proc",
      Path.join(rootfs, "proc"),
      "proc",
      [flags: [:nosuid, :nodev, :noexec]] ++ in_ns
    )
  end

  defp mount_dev(rootfs, in_ns) do
    dev = Path.join(rootfs, "dev")

    with :ok <-
           Mount.mount(
             "tmpfs",
             dev,
             "tmpfs",
             [data: "mode=755,size=1m", flags: [:nosuid]] ++ in_ns
           ) do
      bind_device_nodes(dev, in_ns)
    end
  end

  defp bind_device_nodes(dev, in_ns) do
    Enum.reduce_while(@device_nodes, :ok, fn node, :ok ->
      case Mount.bind("/dev/#{node}", Path.join(dev, node), [create: true] ++ in_ns) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp mount_sys(rootfs, in_ns) do
    Mount.bind("/sys", Path.join(rootfs, "sys"), [flags: [:rec]] ++ in_ns)
  end

  defp bind_etc_files(rootfs, etc_files, in_ns) do
    Enum.reduce_while(etc_files, :ok, fn {host_path, in_rootfs}, :ok ->
      target = Path.join(rootfs, String.trim_leading(in_rootfs, "/"))

      case Mount.bind(host_path, target, [create: true] ++ in_ns) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp mount_volumes(rootfs, volume_mounts, in_ns) do
    Enum.reduce_while(volume_mounts, :ok, fn %{source: src, path: path, read_only: ro}, :ok ->
      target = Path.join(rootfs, String.trim_leading(path, "/"))

      # The mount-point dir is created through the host-visible rootfs path —
      # an empty dir in the shared, content-addressed image rootfs is benign
      # (same acceptance as pivot's /old_root below).
      with :ok <- mkdir(target),
           :ok <- Mount.bind(src, target, in_ns),
           :ok <- seal(target, ro, in_ns) do
        {:cont, :ok}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp mkdir(target) do
    case File.mkdir_p(target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mount_target, target, reason}}
    end
  end

  # A bind can't be born read-only (kernel quirk); seal it with a remount.
  defp seal(_target, false, _in_ns), do: :ok
  defp seal(target, true, in_ns), do: Mount.remount(target, [flags: [:ro, :bind]] ++ in_ns)

  defp pivot(rootfs, in_ns) do
    # pivot_root needs an existing dir under the new root for the old root. An
    # empty /old_root in the (shared, content-addressed) image rootfs is benign.
    old_root = Path.join(rootfs, "old_root")
    File.mkdir_p!(old_root)

    with :ok <- Mount.pivot_root(rootfs, old_root, in_ns) do
      Mount.umount("/old_root", [flags: [:detach]] ++ in_ns)
    end
  end
end
