defmodule Tank.Store.WebTest do
  # The [:tank_web] subtree seam against a real store in a tmp dir — no root.
  use ExUnit.Case, async: false

  alias Tank.Store.Web

  setup_all do
    dir = Path.join(System.tmp_dir!(), "tank-store-web-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  test "put/get/delete/list under the web subtree" do
    assert {:error, :not_found} = Web.get(["users", "u1"])

    :ok = Web.put(["users", "u1"], %{name: "leon"})
    :ok = Web.put(["users", "u2"], %{name: "sam"})
    assert {:ok, %{name: "leon"}} = Web.get(["users", "u1"])

    assert {:ok, children} = Web.list(["users"])

    assert Enum.sort_by(children, &elem(&1, 0)) == [
             {"u1", %{name: "leon"}},
             {"u2", %{name: "sam"}}
           ]

    :ok = Web.delete(["users", "u1"])
    assert {:error, :not_found} = Web.get(["users", "u1"])
    # Deleting a missing node is a no-op, like delete_pod.
    :ok = Web.delete(["users", "u1"])
  end

  test "the web subtree does not shadow or reach the pods subtree" do
    :ok = Web.put(["pods", "impostor"], %{sneaky: true})

    # A web node named "pods" lives under [:tank_web], not [:tank, :pods]:
    # the domain's pod list is untouched.
    refute Enum.any?(Tank.list(), &(&1.name == "impostor"))
    :ok = Web.delete(["pods", "impostor"])
  end
end
