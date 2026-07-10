defmodule Tank.PodTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Tank.{Container, Mount, Nic, Pod, Volume}
  alias Tank.Pod.Network

  describe "Pod.new/1 — happy path" do
    test "normalises a full nested spec of plain maps into a struct tree" do
      {:ok, pod} =
        Pod.new(%{
          name: "web",
          restart: :on_failure,
          volumes: [%{name: "data"}, %{name: "logs", source: {:host, "/var/log/web"}}],
          network: %{
            nics: [
              %{name: "eth0", parent: "eth0", ip: {"10.0.0.5", 24}, gateway: "10.0.0.1"}
            ],
            dns: ["10.0.0.1"]
          },
          containers: [
            %{
              name: "app",
              image: "nginx:1.27",
              command: ["/usr/sbin/nginx"],
              args: ["-g", "daemon off;"],
              env: %{"TZ" => "UTC"},
              working_dir: "/",
              user: "nginx",
              mounts: [%{volume: "data", path: "/var/lib/data"}],
              limits: %{memory: 256 <<< 20, pids: 100, cpu: {50_000, 100_000}}
            }
          ]
        })

      assert %Pod{name: "web", restart: :on_failure} = pod
      assert [%Container{name: "app", image: "nginx:1.27"} = container] = pod.containers
      assert [%Mount{volume: "data", path: "/var/lib/data", read_only: false}] = container.mounts

      assert [%Volume{name: "data", source: :managed}, %Volume{source: {:host, "/var/log/web"}}] =
               pod.volumes

      assert %Network{nics: [%Nic{name: "eth0", mode: :macvlan, ip: {"10.0.0.5", 24}}]} =
               pod.network
    end

    test "defaults: :none network, :always restart, no volumes" do
      {:ok, pod} = Pod.new(%{name: "p", containers: [%{name: "c", image: "alpine"}]})
      assert pod.network == :none
      assert pod.restart == :always
      assert pod.volumes == []
    end

    test "accepts the :host and :none network shortcuts" do
      base = %{name: "p", containers: [%{name: "c", image: "alpine"}]}
      assert {:ok, %Pod{network: :host}} = Pod.new(Map.put(base, :network, :host))
      assert {:ok, %Pod{network: :none}} = Pod.new(Map.put(base, :network, :none))
    end

    test "passes already-built nested structs through unchanged" do
      container = Container.new!(%{name: "c", image: "alpine"})

      assert {:ok, %Pod{containers: [^container]}} =
               Pod.new(%{name: "p", containers: [container]})
    end
  end

  describe "Pod.new/1 — validation" do
    test "rejects an empty container list" do
      assert {:error, :no_containers} = Pod.new(%{name: "p", containers: []})
    end

    test "rejects duplicate container names" do
      assert {:error, {:duplicate, ["c"]}} =
               Pod.new(%{
                 name: "p",
                 containers: [%{name: "c", image: "a"}, %{name: "c", image: "b"}]
               })
    end

    test "rejects duplicate volume names" do
      assert {:error, {:duplicate, ["v"]}} =
               Pod.new(%{
                 name: "p",
                 containers: [%{name: "c", image: "a"}],
                 volumes: [%{name: "v"}, %{name: "v"}]
               })
    end

    test "rejects a mount referencing an undefined volume" do
      assert {:error, {:unknown_volume_refs, [{"c", "nope"}]}} =
               Pod.new(%{
                 name: "p",
                 volumes: [%{name: "data"}],
                 containers: [%{name: "c", image: "a", mounts: [%{volume: "nope", path: "/x"}]}]
               })
    end

    test "rejects an unknown restart policy" do
      assert {:error, {:not_allowed, :sometimes, _}} =
               Pod.new(%{name: "p", restart: :sometimes, containers: [%{name: "c", image: "a"}]})
    end

    test "rejects a blank pod name" do
      assert {:error, {:invalid_name, ""}} =
               Pod.new(%{name: "", containers: [%{name: "c", image: "a"}]})
    end

    test "surfaces a nested container error" do
      assert {:error, {:invalid_image, nil}} =
               Pod.new(%{name: "p", containers: [%{name: "c"}]})
    end

    test "rejects an unknown (typo'd) key, at any level of the tree" do
      assert {:error, {:unknown_keys, [:restartt]}} =
               Pod.new(%{name: "p", restartt: :always, containers: [%{name: "c", image: "a"}]})

      assert {:error, {:unknown_keys, [:imagee]}} =
               Pod.new(%{name: "p", containers: [%{name: "c", imagee: "a", image: "a"}]})
    end
  end

  describe "Container.new/1" do
    test "requires name and image" do
      assert {:error, {:invalid_name, nil}} = Container.new(%{image: "a"})
      assert {:error, {:invalid_image, nil}} = Container.new(%{name: "c"})
    end

    test "accepts the {:rootfs, abs_path} escape hatch but rejects a relative one" do
      assert {:ok, %Container{image: {:rootfs, "/img/rootfs"}}} =
               Container.new(%{name: "c", image: {:rootfs, "/img/rootfs"}})

      assert {:error, {:rootfs_path_not_absolute, "rootfs"}} =
               Container.new(%{name: "c", image: {:rootfs, "rootfs"}})
    end

    test "rejects a non-string env value" do
      assert {:error, {:invalid_env, _}} =
               Container.new(%{name: "c", image: "a", env: %{"PORT" => 8080}})
    end

    test "rejects an unknown limit key and a non-positive value" do
      assert {:error, {:invalid_limit, :swap, _}} =
               Container.new(%{name: "c", image: "a", limits: %{swap: 1}})

      assert {:error, {:invalid_limit, :memory, 0}} =
               Container.new(%{name: "c", image: "a", limits: %{memory: 0}})
    end

    test "rejects two mounts at the same path" do
      assert {:error, {:duplicate, ["/x"]}} =
               Container.new(%{
                 name: "c",
                 image: "a",
                 mounts: [%{volume: "v", path: "/x"}, %{volume: "w", path: "/x"}]
               })
    end

    test "tty defaults to false and accepts a boolean, rejecting non-booleans" do
      assert {:ok, %Container{tty: false}} = Container.new(%{name: "c", image: "a"})
      assert {:ok, %Container{tty: true}} = Container.new(%{name: "c", image: "a", tty: true})

      assert {:error, {:not_allowed, "yes", [true, false]}} =
               Container.new(%{name: "c", image: "a", tty: "yes"})
    end
  end

  describe "Nic.new/1" do
    test "validates the static address and prefix" do
      assert {:ok, %Nic{ip: {"10.0.0.5", 24}}} = Nic.new(%{name: "eth0", ip: {"10.0.0.5", 24}})

      assert {:error, {:invalid_ipv4, "10.0.0.999"}} =
               Nic.new(%{name: "eth0", ip: {"10.0.0.999", 24}})

      assert {:error, {:invalid_ip, {"10.0.0.5", 33}}} =
               Nic.new(%{name: "eth0", ip: {"10.0.0.5", 33}})
    end

    test "accepts :dhcp and :auto parent" do
      assert {:ok, %Nic{ip: :dhcp, parent: :auto}} = Nic.new(%{name: "eth0", ip: :dhcp})
    end

    test "accepts an {:ipam, subnet} intent and validates the CIDR" do
      assert {:ok, %Nic{ip: {:ipam, "10.0.0.0/24"}}} =
               Nic.new(%{name: "eth0", ip: {:ipam, "10.0.0.0/24"}})

      assert {:error, {:invalid_ipam_subnet, "10.0.0.0"}} =
               Nic.new(%{name: "eth0", ip: {:ipam, "10.0.0.0"}})

      assert {:error, {:invalid_ipam_subnet, "10.0.0.0/99"}} =
               Nic.new(%{name: "eth0", ip: {:ipam, "10.0.0.0/99"}})
    end

    test "rejects an unknown mode and a bad gateway" do
      assert {:error, {:not_allowed, :vlan, _}} =
               Nic.new(%{name: "eth0", ip: :dhcp, mode: :vlan})

      assert {:error, {:invalid_ipv4, "nope"}} =
               Nic.new(%{name: "eth0", ip: :dhcp, gateway: "nope"})
    end
  end

  describe "Volume.new/1" do
    test "defaults to a managed source" do
      assert {:ok, %Volume{name: "v", source: :managed}} = Volume.new(%{name: "v"})
    end

    test "rejects a relative host path" do
      assert {:error, {:host_path_not_absolute, "rel"}} =
               Volume.new(%{name: "v", source: {:host, "rel"}})
    end
  end
end
