defmodule Tank.RuntimeTest do
  use ExUnit.Case, async: false

  # The composite needs a real network namespace, so these need root.
  @moduletag :integration
  @moduletag capture_log: true

  import Linx.IP
  alias Linx.Netlink.{Rtnl, Socket}
  alias Linx.Netlink.Rtnl.Address
  alias Tank.Runtime

  # --- spec validation (no root) --------------------------------------------

  describe "spec validation" do
    @describetag :integration

    test "refuses a spec without a :net namespace (would touch the host network)" do
      Process.flag(:trap_exit, true)
      spec = %{argv: ["/bin/true"], namespaces: [:uts]}
      assert {:error, {:bad_spec, :net_namespace_required}} = Runtime.start_link(spec)
    end

    test "refuses a spec without argv" do
      Process.flag(:trap_exit, true)
      assert {:error, {:bad_spec, :argv_required}} = Runtime.start_link(%{namespaces: [:net]})
    end
  end

  # --- the composite, end to end --------------------------------------------

  test "spawns a container and converges its network namespace" do
    spec = %{
      argv: ["/bin/sleep", "60"],
      namespaces: [:net],
      network: %{up: ["lo"], addresses: [{"lo", "10.0.0.1", 32}]},
      owner: self()
    }

    {:ok, container} = Runtime.start_link(spec)

    assert_receive {:tank, :running, host_pid}, 5_000
    assert is_integer(host_pid)

    # The desired address is present inside the container's namespace.
    assert address_in_netns?(host_pid, ~IP"10.0.0.1")

    GenServer.stop(container)
  end

  test "restarts the whole composite on workload death, with a fresh namespace" do
    {:ok, sup} = start_supervised({DynamicSupervisor, strategy: :one_for_one, max_restarts: 10})

    spec = %{
      argv: ["/bin/sleep", "60"],
      namespaces: [:net],
      network: %{up: ["lo"], addresses: [{"lo", "10.0.0.7", 32}]},
      owner: self(),
      restart: :transient
    }

    {:ok, _} = DynamicSupervisor.start_child(sup, Runtime.child_spec(spec))

    assert_receive {:tank, :running, host_pid1}, 5_000
    assert address_in_netns?(host_pid1, ~IP"10.0.0.7")

    # Kill the workload out of band; the composite is torn down and the
    # supervisor restarts it with a brand-new namespace, reconfigured afresh.
    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(host_pid1)])

    assert_receive {:tank, :running, host_pid2}, 5_000
    assert host_pid2 != host_pid1
    assert address_in_netns?(host_pid2, ~IP"10.0.0.7")
  end

  defp address_in_netns?(host_pid, ip) do
    {:ok, sock} = Rtnl.open({:pid, host_pid})

    try do
      {:ok, addrs} = Address.list(sock)
      Enum.any?(addrs, &(&1.address == ip))
    after
      Socket.close(sock)
    end
  end
end
