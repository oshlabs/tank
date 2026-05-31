defmodule Tank.StoreTest do
  # Boots a real Khepri/Ra store in a tmp dir -- no root needed, but a singleton,
  # so not async.
  use ExUnit.Case, async: false

  # Ra/Khepri log a lot at :debug during leader election; keep test output clean.
  @moduletag capture_log: true

  alias Tank.{Pod, Store}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "tank-store-test-#{System.unique_integer([:positive])}")
    start_supervised!({Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    # Clean slate: drop any pods a prior test left behind.
    for pod <- Store.list_pods(), do: Store.delete_pod(pod.name)
    :ok
  end

  defp pod(name, attrs \\ %{}) do
    Pod.new!(Map.merge(%{name: name, containers: [%{name: "c", image: "alpine"}]}, attrs))
  end

  test "put_pod then get_pod round-trips the struct" do
    p = pod("web", %{restart: :on_failure})
    assert :ok = Store.put_pod(p)
    assert {:ok, ^p} = Store.get_pod("web")
  end

  test "get_pod on a missing name is {:error, :not_found}" do
    assert {:error, :not_found} = Store.get_pod("nope")
  end

  test "put_pod overwrites an existing pod" do
    assert :ok = Store.put_pod(pod("web", %{restart: :always}))
    assert :ok = Store.put_pod(pod("web", %{restart: :never}))
    assert {:ok, %Pod{restart: :never}} = Store.get_pod("web")
  end

  test "create_pod is create-if-absent" do
    assert :ok = Store.create_pod(pod("web"))
    assert {:error, :exists} = Store.create_pod(pod("web"))
    # The original is untouched.
    assert {:ok, %Pod{name: "web"}} = Store.get_pod("web")
  end

  test "delete_pod removes it; deleting a missing pod is :ok" do
    assert :ok = Store.put_pod(pod("web"))
    assert :ok = Store.delete_pod("web")
    assert {:error, :not_found} = Store.get_pod("web")
    assert :ok = Store.delete_pod("web")
  end

  test "list_pods reflects writes and deletes via the projection" do
    assert Store.list_pods() == []

    :ok = Store.put_pod(pod("web"))
    :ok = Store.put_pod(pod("db"))

    names = Store.list_pods() |> Enum.map(& &1.name) |> Enum.sort()
    assert names == ["db", "web"]

    :ok = Store.delete_pod("db")
    assert Store.list_pods() |> Enum.map(& &1.name) == ["web"]
  end
end
