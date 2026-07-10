defmodule Tank.Runtime.Etc do
  @moduledoc false

  # Per-pod /etc files materialised on the host and bound into the rootfs before
  # pivot (the image rootfs is shared and content-addressed, so it must not be
  # mutated per pod). Returns `{host_path, in_rootfs_path}` pairs for
  # `Tank.Runtime.Rootfs.setup/3`.

  alias Tank.{Host, Pod}

  @doc "Write resolv.conf + hosts + hostname into `dir`; return the bind pairs for the rootfs."
  @spec materialize(Pod.t(), Path.t()) :: [{Path.t(), Path.t()}]
  def materialize(%Pod{} = pod, dir) do
    File.mkdir_p!(dir)

    resolv = Path.join(dir, "resolv.conf")
    hosts = Path.join(dir, "hosts")
    hostname = Path.join(dir, "hostname")
    File.write!(resolv, resolv_conf(pod))
    File.write!(hosts, hosts_file(pod))
    # The file counterpart of the UTS hostname the runtime sets at bring-up —
    # images bake their build hostname in (debian: "debuerreotype").
    File.write!(hostname, pod.name <> "\n")

    [
      {resolv, "/etc/resolv.conf"},
      {hosts, "/etc/hosts"},
      {hostname, "/etc/hostname"}
    ]
  end

  # A networked pod that names its own DNS uses it; one that doesn't inherits the
  # host's (via the Tank.Host seam). `:none` / `:host` pods get an empty file.
  defp resolv_conf(%Pod{network: %Pod.Network{dns: [_ | _] = dns}}), do: nameservers(dns)
  defp resolv_conf(%Pod{network: %Pod.Network{dns: []}}), do: nameservers(Host.dns())
  defp resolv_conf(_pod), do: ""

  defp nameservers(list), do: Enum.map_join(list, fn ns -> "nameserver #{ns}\n" end)

  defp hosts_file(%Pod{name: name}) do
    "127.0.0.1\tlocalhost #{name}\n::1\tlocalhost ip6-localhost\n"
  end
end
