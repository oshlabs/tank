defmodule Tank.Runtime.Network do
  @moduledoc """
  Configures a pod's network namespace at the `Linx.Process` `:ready`
  checkpoint. A pod's `:network` is one of:

    * `:host` — the workload shares the host's network namespace (the runtime
      simply doesn't give it a fresh `:net` ns), so there is nothing to do here.
    * `:none` — an isolated netns with loopback only.
    * `%Tank.Pod.Network{}` — loopback plus one or more `%Tank.Nic{}`.

  Each macvlan NIC is **created in the host netns over its parent uplink, then
  moved into the container's netns**, and renamed / addressed / brought up
  there — a macvlan can't be created directly in the container over a parent
  that lives in the host netns. The host-side name is transient because the
  final name (e.g. `eth0`) usually collides with a host interface.

  DNS (`/etc/resolv.conf`) is materialised by the orchestrator (`Tank.Runtime`)
  during rootfs setup, not here.
  """

  require Logger

  alias Linx.Netlink.{Rtnl, Socket}
  alias Linx.Netlink.Rtnl.{Address, Link, Route}
  alias Tank.Nic
  alias Tank.Pod.Network

  @doc "Configure the netns of the container parked at `host_pid`."
  @spec setup(pos_integer(), Network.t() | :host | :none) :: :ok | {:error, term()}
  def setup(_host_pid, :host), do: :ok

  def setup(host_pid, :none), do: in_netns(host_pid, &Link.set_up(&1, "lo"))

  def setup(host_pid, %Network{nics: nics}) do
    with :ok <- in_netns(host_pid, &Link.set_up(&1, "lo")) do
      Enum.reduce_while(nics, :ok, fn nic, :ok ->
        case setup_nic(host_pid, nic) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  # --- one NIC -------------------------------------------------------------

  defp setup_nic(_host_pid, %Nic{parent: :auto}) do
    # `:auto` parent resolution is Tank.Host's job (M6); not available yet.
    {:error, {:parent_auto_unsupported, "set an explicit :parent until Tank.Host (M6)"}}
  end

  defp setup_nic(host_pid, %Nic{mode: :macvlan} = nic) do
    tmp = transient_name()

    with :ok <- create_and_move(host_pid, nic, tmp) do
      configure(host_pid, nic, tmp)
    end
  end

  defp setup_nic(_host_pid, %Nic{mode: mode}), do: {:error, {:nic_mode_unsupported, mode}}

  defp create_and_move(host_pid, %Nic{parent: parent}, tmp) do
    in_host(fn sock ->
      with :ok <- Link.create_macvlan(sock, tmp, parent, :bridge) do
        Link.move_to_netns(sock, tmp, host_pid)
      end
    end)
  end

  defp configure(host_pid, %Nic{} = nic, tmp) do
    in_netns(host_pid, fn sock ->
      with :ok <- Link.set_name(sock, tmp, nic.name),
           :ok <- Link.set_up(sock, nic.name),
           :ok <- add_address(sock, nic) do
        add_gateway(sock, nic)
      end
    end)
  end

  defp add_address(_sock, %Nic{ip: :dhcp}) do
    Logger.warning("Tank.Runtime.Network: :dhcp is not implemented; NIC left without an address")
    :ok
  end

  defp add_address(sock, %Nic{name: name, ip: {addr, prefix}}),
    do: Address.add(sock, name, addr, prefix)

  defp add_gateway(_sock, %Nic{gateway: nil}), do: :ok
  defp add_gateway(sock, %Nic{gateway: gw}), do: Route.add_default(sock, gw)

  # --- socket helpers ------------------------------------------------------

  defp in_host(fun), do: with_socket(Rtnl.open(), fun)
  defp in_netns(host_pid, fun), do: with_socket(Rtnl.open({:pid, host_pid}), fun)

  defp with_socket({:ok, sock}, fun) do
    try do
      fun.(sock)
    after
      Socket.close(sock)
    end
  end

  defp with_socket({:error, _} = err, _fun), do: err

  # A transient host-side interface name within IFNAMSIZ (16 incl. NUL).
  defp transient_name, do: "tank#{rem(System.unique_integer([:positive]), 1_000_000)}"
end
