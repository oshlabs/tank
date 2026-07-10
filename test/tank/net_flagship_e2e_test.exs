defmodule Tank.NetFlagshipE2eTest do
  # The networking stack's user story, end to end, witnessed from INSIDE a
  # pod: a real deckhand container on an {:ipam, subnet} NIC — address
  # allocated by the embedded IPAM, reached from the host *through the shim*
  # (macvlan pods can't hairpin the parent), resolving names via the embedded
  # DNS listener on the shim, and pinging the shim over the macvlan.
  # Needs root; hermetic — the image comes from a local Stevedore registry
  # and the uplink is a dummy interface. Run via ./sudotest.sh.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true
  @moduletag timeout: 120_000

  alias Starfish.IPAM
  alias Tank.{Net, Pod, Runtime}

  @parent "tankflagd0"
  @shim "tankflag0"
  @pool "10.96.3.0/29"

  setup do
    {_, 0} = System.cmd("ip", ["link", "add", @parent, "type", "dummy"], stderr_to_stdout: true)
    {_, 0} = System.cmd("ip", ["link", "set", @parent, "up"], stderr_to_stdout: true)

    on_exit(fn ->
      System.cmd("ip", ["link", "del", @shim], stderr_to_stdout: true)
      System.cmd("ip", ["link", "del", @parent], stderr_to_stdout: true)
      Net.clear_dns_ips()
    end)

    deck = Tank.TestImages.deckhand!()

    table = :"net_flag_#{System.unique_integer([:positive])}"
    start_supervised!({Starfish.Store.Memory, name: table})

    start_supervised!(
      {IPAM.Server,
       store: {Starfish.Store.Memory, table},
       sweep_interval: 0,
       desired: %{prefixes: [%{subnet: @pool}], reservations: []}}
    )

    start_supervised!(
      {Starfish.Servers.Supervisor, store: {Starfish.Store.Memory, table}, ipam: IPAM.Server}
    )

    # The boot actuator: shim on the dummy uplink, DNS listener on the shim's
    # address — real port 53 (resolv.conf carries no port), hence root.
    start_supervised!(
      {Tank.Net.Services, [shim: [name: @shim, parent: @parent], dns: [origin: "tank.test"]]}
    )

    %{deck: deck}
  end

  test "a pod sees its IPAM address, resolves names via the shim DNS, and pings the shim",
       %{deck: deck} do
    pod =
      Pod.new!(
        name: "flag",
        containers: [%{name: "app", image: deck.ref}],
        network: %{nics: [%{name: "eth0", parent: @parent, ip: {:ipam, @pool}}]}
      )

    {:ok, runtime} = Runtime.start_link(pod, owner: self(), image: deck.image_opts)
    assert_receive {:tank, _, {:running, _host_pid}}, 30_000

    assert [shim_ip] = Net.dns_ips()
    {:ok, alloc} = IPAM.lookup({:tank_pod, "flag", "eth0"})
    pod_ip = Starfish.IP.to_string(alloc.ip)

    # Host → pod, through the shim (macvlan siblings on the dummy parent):
    # deckhand answers HTTP, and its own view carries the allocated address.
    assert {:ok, 200, ifaces} = http_get(pod_ip, 8080, "/ifaces")
    assert ifaces =~ pod_ip

    # The resolv.conf chain landed the shim as the pod's nameserver.
    assert {:ok, 200, resolv} = http_get(pod_ip, 8080, "/cat/etc/resolv.conf")
    assert resolv =~ "nameserver #{shim_ip}"

    # From INSIDE the pod, names resolve through the embedded DNS on the shim:
    # the pod's own name (the allocation's hostname)...
    assert {:ok, 200, self_answer} = http_get(pod_ip, 8080, "/resolve/flag.tank.test")
    assert self_answer =~ "A #{pod_ip}"

    # ...and the host's ("tank" — the shim allocation's hostname).
    assert {:ok, 200, host_answer} = http_get(pod_ip, 8080, "/resolve/tank.tank.test")
    assert host_answer =~ "A #{shim_ip}"

    # And the pod reaches the host over the macvlan: one ICMP echo to the shim.
    assert {:ok, 200, ping} = http_get(pod_ip, 8080, "/ping/#{shim_ip}")
    assert ping =~ "reply: time=", "expected an echo reply, got: #{inspect(ping)}"

    GenServer.stop(runtime)
  end

  # -- tiny HTTP client (deckhand answers and closes) -------------------------

  defp http_get(host, port, path, attempts \\ 40) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 500) do
      {:ok, sock} ->
        :ok = :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: test\r\n\r\n")
        response = recv_all(sock, "")
        :gen_tcp.close(sock)
        ["HTTP/1.1 " <> status_line | _] = String.split(response, "\r\n")
        [status | _] = String.split(status_line, " ")
        [_head, body] = String.split(response, "\r\n\r\n", parts: 2)
        {:ok, String.to_integer(status), body}

      {:error, reason} when reason in [:econnrefused, :ehostunreach, :timeout] and attempts > 0 ->
        # deckhand may still be booting its listener (or ARP settling); retry.
        Process.sleep(100)
        http_get(host, port, path, attempts - 1)
    end
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end
end
