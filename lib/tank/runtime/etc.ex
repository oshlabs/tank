defmodule Tank.Runtime.Etc do
  @moduledoc false

  # Per-pod /etc files materialised on the host and bound into the rootfs before
  # pivot (the image rootfs is shared and content-addressed, so it must not be
  # mutated per pod). Returns `{host_path, in_rootfs_path}` pairs for
  # `Tank.Runtime.Rootfs.setup/3`.

  alias Tank.Pod

  @doc "Write resolv.conf + hosts into `dir`; return the bind pairs for the rootfs."
  @spec materialize(Pod.t(), Path.t()) :: [{Path.t(), Path.t()}]
  def materialize(%Pod{} = pod, dir) do
    File.mkdir_p!(dir)

    resolv = Path.join(dir, "resolv.conf")
    hosts = Path.join(dir, "hosts")
    File.write!(resolv, resolv_conf(pod))
    File.write!(hosts, hosts_file(pod))

    [{resolv, "/etc/resolv.conf"}, {hosts, "/etc/hosts"}]
  end

  defp resolv_conf(%Pod{network: %Pod.Network{dns: [_ | _] = dns}}) do
    Enum.map_join(dns, fn ns -> "nameserver #{ns}\n" end)
  end

  defp resolv_conf(_pod), do: ""

  defp hosts_file(%Pod{name: name}) do
    "127.0.0.1\tlocalhost #{name}\n::1\tlocalhost ip6-localhost\n"
  end
end
