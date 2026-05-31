defmodule TankTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Tank.Pod

  setup_all do
    dir = Path.join(System.tmp_dir!(), "tank-api-test-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    for pod <- Tank.list(), do: Tank.delete(pod.name)
    :ok
  end

  describe "apply/1" do
    test "accepts a plain spec map, validates it, and stores it" do
      assert :ok = Tank.apply(%{name: "web", containers: [%{name: "app", image: "nginx:1.27"}]})
      assert {:ok, %Pod{name: "web"}} = Tank.get("web")
      assert ["web"] = Tank.list() |> Enum.map(& &1.name)
    end

    test "accepts an already-built %Tank.Pod{}" do
      pod = Pod.new!(%{name: "web", containers: [%{name: "c", image: "alpine"}]})
      assert :ok = Tank.apply(pod)
      assert {:ok, ^pod} = Tank.get("web")
    end

    test "returns the validation error for an invalid spec (and stores nothing)" do
      assert {:error, {:invalid_image, nil}} =
               Tank.apply(%{name: "web", containers: [%{name: "c"}]})

      assert Tank.list() == []
    end

    test "replaces an existing pod" do
      assert :ok =
               Tank.apply(%{
                 name: "web",
                 restart: :always,
                 containers: [%{name: "c", image: "a"}]
               })

      assert :ok =
               Tank.apply(%{name: "web", restart: :never, containers: [%{name: "c", image: "a"}]})

      assert {:ok, %Pod{restart: :never}} = Tank.get("web")
    end
  end

  describe "delete/1" do
    test "removes by name and by struct" do
      :ok = Tank.apply(%{name: "web", containers: [%{name: "c", image: "a"}]})
      assert :ok = Tank.delete("web")
      assert {:error, :not_found} = Tank.get("web")

      pod = Pod.new!(%{name: "db", containers: [%{name: "c", image: "a"}]})
      :ok = Tank.apply(pod)
      assert :ok = Tank.delete(pod)
      assert {:error, :not_found} = Tank.get("db")
    end
  end

  describe "seed/1 (bootstrap, create-if-absent)" do
    test "writes pods that are absent" do
      assert :ok = Tank.seed([%{name: "web", containers: [%{name: "c", image: "a"}]}])
      assert ["web"] = Tank.list() |> Enum.map(& &1.name)
    end

    test "does NOT clobber a pod changed at runtime" do
      # Runtime state: restart :never.
      :ok = Tank.apply(%{name: "web", restart: :never, containers: [%{name: "c", image: "a"}]})

      # Boot seed says :always -- but the pod already exists, so seed leaves it.
      :ok = Tank.seed([%{name: "web", restart: :always, containers: [%{name: "c", image: "a"}]}])

      assert {:ok, %Pod{restart: :never}} = Tank.get("web")
    end

    test "logs and skips an invalid seed entry without raising" do
      assert :ok =
               Tank.seed([%{name: "ok", containers: [%{name: "c", image: "a"}]}, %{name: "bad"}])

      assert ["ok"] = Tank.list() |> Enum.map(& &1.name)
    end
  end
end
