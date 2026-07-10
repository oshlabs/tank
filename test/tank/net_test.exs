defmodule Tank.NetTest do
  # The IPAM server registers under Starfish's default name (the one
  # Tank.Net targets), so these tests can't run concurrently.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Starfish.IPAM
  alias Tank.{Net, Nic, Pod}

  defp pod(name, nics, extra \\ []) do
    Pod.new!(
      name: name,
      containers: [%{name: "main", image: "example/app:1"}],
      network: Enum.into(extra, %{nics: nics})
    )
  end

  describe "with the embedded IPAM running" do
    setup do
      table = :"tank_net_test_#{System.unique_integer([:positive])}"
      start_supervised!({Starfish.Store.Memory, name: table})

      start_supervised!(
        {IPAM.Server,
         store: {Starfish.Store.Memory, table},
         sweep_interval: 0,
         desired: %{
           prefixes: [%{subnet: "10.9.0.0/29", gateway: "10.9.0.1", dns: ["10.9.0.1"]}],
           reservations: []
         }}
      )

      :ok
    end

    test "resolve allocates a static address and defaults the gateway from the pool" do
      pod = pod("web", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}}])

      assert {:ok, network} = Net.resolve(pod)
      assert [%Nic{ip: {addr, 29}, gateway: "10.9.0.1"}] = network.nics
      assert addr =~ ~r/^10\.9\.0\.\d+$/

      # The allocation is static (never expires), keyed on {:tank_pod, pod, nic},
      # with the pod name as DNS hostname.
      assert {:ok, alloc} = IPAM.lookup({:tank_pod, "web", "eth0"})
      assert alloc.source == :static
      assert alloc.expires_at == nil
      assert alloc.hostname == "web"
    end

    test "an explicit NIC gateway wins over the pool's" do
      pod = pod("web", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}, gateway: "10.9.0.6"}])

      assert {:ok, network} = Net.resolve(pod)
      assert [%Nic{gateway: "10.9.0.6"}] = network.nics
    end

    test "resolv.conf chain: empty pod dns defaults from the pool's" do
      pod = pod("web", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}}])
      assert {:ok, %{dns: ["10.9.0.1"]}} = Net.resolve(pod)
    end

    test "resolv.conf chain: explicit pod dns wins over the pool's" do
      pod = pod("web", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}}], dns: ["9.9.9.9"])
      assert {:ok, %{dns: ["9.9.9.9"]}} = Net.resolve(pod)
    end

    test "resolv.conf chain: a pool without dns falls back to the DNS service's address" do
      :ok = IPAM.put_prefix(%{subnet: "10.9.1.0/29"})
      Net.put_dns_ips(["10.9.1.2"])
      on_exit(fn -> Net.clear_dns_ips() end)

      pod = pod("web", [%{name: "eth0", ip: {:ipam, "10.9.1.0/29"}}])
      assert {:ok, %{dns: ["10.9.1.2"]}} = Net.resolve(pod)
    end

    test "a restarting pod gets its previous address back (affinity)" do
      pod = pod("web", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}}])

      assert {:ok, %{nics: [%Nic{ip: first}]}} = Net.resolve(pod)
      assert {:ok, %{nics: [%Nic{ip: ^first}]}} = Net.resolve(pod)
    end

    test "static and pass-through networks resolve untouched" do
      static = pod("db", [%{name: "eth0", ip: {"10.9.0.4", 29}}])
      assert {:ok, %{nics: [%Nic{ip: {"10.9.0.4", 29}}], dns: []}} = Net.resolve(static)

      host = Pod.new!(name: "h", containers: [%{name: "m", image: "i:1"}], network: :host)
      assert {:ok, :host} = Net.resolve(host)
    end

    test "an unknown pool fails bring-up with a tagged error" do
      pod = pod("web", [%{name: "eth0", ip: {:ipam, "192.168.0.0/24"}}])
      assert {:error, {:ipam_allocate_failed, "eth0", _}} = Net.resolve(pod)
    end

    test "reconcile releases allocations of pods that left desired state, never the shim's" do
      {:ok, _} = Net.resolve(pod("keep", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}}]))
      {:ok, _} = Net.resolve(pod("gone", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}}]))

      {:ok, _} =
        IPAM.allocate("10.9.0.0/29", {:tank_host, :shim}, source: :static, hostname: "tank")

      assert :ok = Net.reconcile(["keep"])

      assert {:ok, _} = IPAM.lookup({:tank_pod, "keep", "eth0"})
      assert :error = IPAM.lookup({:tank_pod, "gone", "eth0"})
      assert {:ok, _} = IPAM.lookup({:tank_host, :shim})
    end
  end

  describe "attached to Tank's Khepri store (one store, two subtrees)" do
    setup do
      id = System.unique_integer([:positive])
      dir = Path.join(System.tmp_dir!(), "tank-net-khepri-#{id}")
      store_id = :"tank_net_#{id}"

      start_supervised!({Tank.Store, data_dir: dir, store_id: store_id})
      on_exit(fn -> File.rm_rf!(dir) end)

      specs =
        Net.child_specs(
          [pools: [%{subnet: "10.8.0.0/29", gateway: "10.8.0.1"}], dns: false],
          store_id: store_id
        )

      for spec <- specs, do: start_supervised!(spec)

      %{store_id: store_id}
    end

    test "the adapter attaches instead of starting its own store, and the data lands under [:starfish]",
         %{store_id: store_id} do
      assert {:ok, %{nics: [%Nic{ip: {_, 29}, gateway: "10.8.0.1"}]}} =
               Net.resolve(pod("web", [%{name: "eth0", ip: {:ipam, "10.8.0.0/29"}}]))

      # One Khepri store: Tank's. No default Starfish store was booted.
      ids = :khepri_cluster.get_store_ids()
      assert store_id in ids
      refute :starfish_store in ids

      # Starfish's data sits in its own raw subtree next to Tank's [:tank, …].
      assert {:ok, subtree} =
               :khepri.get_many(store_id, [:starfish, {:if_path_matches, :any, :undefined}])

      assert map_size(subtree) > 0
    end
  end

  describe "without the embedded IPAM" do
    test "an {:ipam, _} NIC fails bring-up with a clear error" do
      pod = pod("web", [%{name: "eth0", ip: {:ipam, "10.9.0.0/29"}}])
      assert {:error, {:ipam_not_running, "eth0"}} = Net.resolve(pod)
    end

    test "pods without IPAM intents resolve fine, and reconcile is a no-op" do
      pod = pod("db", [%{name: "eth0", ip: {"10.9.0.4", 29}}])
      assert {:ok, _} = Net.resolve(pod)
      assert :ok = Net.reconcile([])
    end
  end

  describe "child_specs/2" do
    test "nothing to start without :net config" do
      assert Net.child_specs(nil) == []
      assert Net.child_specs([]) == []
    end

    test "attaches the Starfish adapter to Tank's store id and seeds the pools" do
      specs = Net.child_specs([pools: [%{subnet: "10.0.0.0/24"}], dns: false], store_id: :custom)

      assert [
               {Starfish.Store.Khepri, name: :custom},
               {Starfish.IPAM.Server, server_opts}
             ] = specs

      assert server_opts[:store] == {Starfish.Store.Khepri, {:custom, [:starfish]}}
      assert %{prefixes: [%{subnet: "10.0.0.0/24"}]} = server_opts[:desired]
      # No :data_dir — the adapter must attach, never boot a second store.
      refute Keyword.has_key?(specs |> hd() |> elem(1), :data_dir)
    end

    test "the DNS service defaults on: listener subtree + boot actuator" do
      specs = Net.child_specs([pools: [%{subnet: "10.0.0.0/24"}]], store_id: :custom)

      assert [
               {Starfish.Store.Khepri, _},
               {Starfish.IPAM.Server, _},
               {Starfish.Servers.Supervisor, servers_opts},
               {Tank.Net.Services, _}
             ] = specs

      assert servers_opts[:store] == {Starfish.Store.Khepri, {:custom, [:starfish]}}
    end

    test "no declared pools means no :desired (a durable store is never wiped)" do
      assert [_store, {Starfish.IPAM.Server, server_opts} | _] =
               Net.child_specs(dns: false, shim: false)

      refute Keyword.has_key?(server_opts, :desired)
    end
  end
end
