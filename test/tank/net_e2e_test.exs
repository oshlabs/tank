defmodule Tank.NetE2eTest do
  # The full DNS-service stack on a real (dummy) uplink: the shim macvlan is
  # created in the host netns, the listener binds its address, and a pod's
  # name resolves to its allocation. Needs root — run via ./sudotest.sh.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  alias Starfish.DNS.Client
  alias Starfish.DNS.Record
  alias Starfish.IPAM
  alias Tank.{Net, Nic, Pod}

  @parent "tanknetdummy0"
  @shim "tanktest0"
  @pool "10.97.0.0/29"
  # An unprivileged-range port so this e2e never fights anything bound on :53.
  @port 15353

  setup do
    {_, 0} = System.cmd("ip", ["link", "add", @parent, "type", "dummy"], stderr_to_stdout: true)
    {_, 0} = System.cmd("ip", ["link", "set", @parent, "up"], stderr_to_stdout: true)

    on_exit(fn ->
      System.cmd("ip", ["link", "del", @shim], stderr_to_stdout: true)
      System.cmd("ip", ["link", "del", @parent], stderr_to_stdout: true)
      Net.clear_dns_ips()
    end)

    table = :"net_e2e_#{System.unique_integer([:positive])}"
    start_supervised!({Starfish.Store.Memory, name: table})

    start_supervised!(
      {IPAM.Server,
       store: {Starfish.Store.Memory, table},
       sweep_interval: 0,
       desired: %{
         prefixes: [%{subnet: @pool, gateway: "10.97.0.1"}],
         reservations: []
       }}
    )

    start_supervised!(
      {Starfish.Servers.Supervisor, store: {Starfish.Store.Memory, table}, ipam: IPAM.Server}
    )

    start_supervised!(
      {Tank.Net.Services,
       [
         shim: [name: @shim, parent: @parent],
         dns: [origin: "tank.test", port: @port]
       ]}
    )

    :ok
  end

  test "a pod name resolves through the shim listener" do
    pod =
      Pod.new!(
        name: "web",
        containers: [%{name: "main", image: "unused"}],
        network: %{nics: [%{name: "eth0", parent: @parent, ip: {:ipam, @pool}}]}
      )

    assert {:ok, net} = Net.resolve(pod)
    assert [%Nic{ip: {addr, 29}, gateway: "10.97.0.1"}] = net.nics

    # resolv.conf chain: the pool declares no dns, so the pod gets the DNS
    # service's own (shim) address.
    assert [shim_ip] = Net.dns_ips()
    assert net.dns == [shim_ip]

    # The shim exists in the host netns and carries that address.
    {out, 0} = System.cmd("ip", ["-o", "addr", "show", "dev", @shim], stderr_to_stdout: true)
    assert out =~ shim_ip

    # The pod's name resolves against the listener on the shim address, to the
    # address the pod was just allocated.
    {:ok, expected} = Starfish.IP.parse(addr)

    assert {:ok, [%Record{type: :a, rdata: ^expected}]} =
             Client.resolve("web.tank.test", :a, server: shim_ip, port: @port)

    # The host itself has a name too (the shim allocation's hostname).
    {:ok, shim_expected} = Starfish.IP.parse(shim_ip)

    assert {:ok, [%Record{type: :a, rdata: ^shim_expected}]} =
             Client.resolve("tank.tank.test", :a, server: shim_ip, port: @port)

    # Reverse resolution comes free from the same zone.
    reverse =
      addr |> String.split(".") |> Enum.reverse() |> Enum.join(".") |> Kernel.<>(".in-addr.arpa")

    assert {:ok, [%Record{type: :ptr, rdata: "web.tank.test"}]} =
             Client.resolve(reverse, :ptr, server: shim_ip, port: @port)
  end
end
