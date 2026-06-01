defmodule Tank.Runtime.EtcTest do
  use ExUnit.Case, async: false

  alias Tank.{Host, Pod}
  alias Tank.Runtime.Etc

  setup do
    dir = Path.join(System.tmp_dir!(), "tank-etc-#{System.unique_integer([:positive])}")
    original = Application.get_env(:tank, Host.Static)

    on_exit(fn ->
      File.rm_rf(dir)

      if original,
        do: Application.put_env(:tank, Host.Static, original),
        else: Application.delete_env(:tank, Host.Static)
    end)

    {:ok, dir: dir}
  end

  defp resolv(dir), do: File.read!(Path.join(dir, "resolv.conf"))

  defp pod(network) do
    Pod.new!(%{name: "p", network: network, containers: [%{name: "c", image: "alpine"}]})
  end

  test "a pod's explicit DNS is written verbatim", %{dir: dir} do
    Application.put_env(:tank, Host.Static, dns: ["10.0.0.1"])
    Etc.materialize(pod(%{dns: ["1.1.1.1", "8.8.8.8"]}), dir)

    # The pod's own DNS wins over the host's.
    assert resolv(dir) == "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
  end

  test "a networked pod with no DNS inherits the host's", %{dir: dir} do
    Application.put_env(:tank, Host.Static, dns: ["10.0.0.1"])
    Etc.materialize(pod(%{}), dir)

    assert resolv(dir) == "nameserver 10.0.0.1\n"
  end

  test "a :none pod gets an empty resolv.conf regardless of host DNS", %{dir: dir} do
    Application.put_env(:tank, Host.Static, dns: ["10.0.0.1"])
    Etc.materialize(pod(:none), dir)

    assert resolv(dir) == ""
  end
end
