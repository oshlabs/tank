defmodule Tank.Runtime.NetworkTest do
  # Real netns + macvlan over a dummy uplink: needs root. Run via ./sudotest.sh.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  import Linx.IP

  alias Linx.Netlink.{Rtnl, Socket}
  alias Linx.Netlink.Rtnl.{Address, Link}
  alias Tank.Pod.Network
  alias Tank.Runtime.Network, as: Net

  @parent "tankdummy0"

  setup do
    # A dummy parent uplink in the host netns for the macvlan to attach to.
    {_, 0} = System.cmd("ip", ["link", "add", @parent, "type", "dummy"], stderr_to_stdout: true)
    {_, 0} = System.cmd("ip", ["link", "set", @parent, "up"], stderr_to_stdout: true)
    on_exit(fn -> System.cmd("ip", ["link", "del", @parent], stderr_to_stdout: true) end)
    :ok
  end

  defp spawn_netns do
    {:ok, session} = Linx.Process.spawn(argv: ["/bin/sleep", "30"], namespaces: [:net])
    assert_receive {:linx_process, :ready, host_pid}, 2_000
    {session, host_pid}
  end

  defp links_in_netns(host_pid) do
    {:ok, sock} = Rtnl.open({:pid, host_pid})

    try do
      {:ok, links} = Link.list(sock)
      Enum.map(links, & &1.name)
    after
      Socket.close(sock)
    end
  end

  defp addresses_in_netns(host_pid, link) do
    {:ok, sock} = Rtnl.open({:pid, host_pid})

    try do
      {:ok, addrs} = Address.list(sock, link)
      Enum.map(addrs, & &1.address)
    after
      Socket.close(sock)
    end
  end

  test "creates a macvlan in the container's netns with the desired address" do
    {session, host_pid} = spawn_netns()

    net =
      Network.new!(%{
        nics: [%{name: "eth0", parent: @parent, ip: {"10.99.0.5", 24}, gateway: "10.99.0.1"}]
      })

    assert :ok = Net.setup(host_pid, net)

    assert "eth0" in links_in_netns(host_pid)
    assert ~IP"10.99.0.5" in addresses_in_netns(host_pid, "eth0")

    Linx.Process.abort(session)
  end

  test "the macvlan does NOT leak into the host netns" do
    {session, host_pid} = spawn_netns()

    net = Network.new!(%{nics: [%{name: "eth0", parent: @parent, ip: {"10.99.0.6", 24}}]})
    assert :ok = Net.setup(host_pid, net)

    # The host sees only its own interfaces (lo, the dummy parent) -- not eth0.
    {:ok, host_sock} = Rtnl.open()
    {:ok, host_links} = Link.list(host_sock)
    Socket.close(host_sock)
    host_names = Enum.map(host_links, & &1.name)

    assert @parent in host_names
    refute "eth0" in host_names

    Linx.Process.abort(session)
  end

  test ":none brings up loopback and nothing else" do
    {session, host_pid} = spawn_netns()
    assert :ok = Net.setup(host_pid, :none)
    assert "lo" in links_in_netns(host_pid)
    Linx.Process.abort(session)
  end

  test ":host is a no-op" do
    assert :ok = Net.setup(1, :host)
  end

  test "an :auto parent resolves the uplink via the Tank.Host seam" do
    original = Application.get_env(:tank, Tank.Host.Static)
    Application.put_env(:tank, Tank.Host.Static, uplink: @parent)

    on_exit(fn ->
      if original,
        do: Application.put_env(:tank, Tank.Host.Static, original),
        else: Application.delete_env(:tank, Tank.Host.Static)
    end)

    {session, host_pid} = spawn_netns()
    net = Network.new!(%{nics: [%{name: "eth0", parent: :auto, ip: {"10.99.0.7", 24}}]})

    assert :ok = Net.setup(host_pid, net)
    assert "eth0" in links_in_netns(host_pid)
    assert ~IP"10.99.0.7" in addresses_in_netns(host_pid, "eth0")

    Linx.Process.abort(session)
  end

  test "an :auto parent fails clearly when no uplink is configured" do
    original = Application.get_env(:tank, Tank.Host.Static)
    Application.delete_env(:tank, Tank.Host.Static)
    on_exit(fn -> if original, do: Application.put_env(:tank, Tank.Host.Static, original) end)

    {session, host_pid} = spawn_netns()
    net = Network.new!(%{nics: [%{name: "eth0", parent: :auto, ip: {"10.99.0.8", 24}}]})

    assert {:error, {:no_uplink, :no_uplink_configured}} = Net.setup(host_pid, net)

    Linx.Process.abort(session)
  end
end
