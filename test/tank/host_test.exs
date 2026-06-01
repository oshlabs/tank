defmodule Tank.HostTest do
  use ExUnit.Case, async: false

  alias Tank.Host

  defmodule StubAdapter do
    @behaviour Tank.Host
    @impl Tank.Host
    def uplink, do: {:ok, "stub0"}
    @impl Tank.Host
    def dns, do: ["9.9.9.9"]
  end

  describe "Tank.Host.Static" do
    setup do
      original = Application.get_env(:tank, Host.Static)

      on_exit(fn ->
        if original,
          do: Application.put_env(:tank, Host.Static, original),
          else: Application.delete_env(:tank, Host.Static)
      end)

      :ok
    end

    test "reads uplink and dns from config" do
      Application.put_env(:tank, Host.Static, uplink: "eth0", dns: ["10.0.0.1"])
      assert {:ok, "eth0"} = Host.Static.uplink()
      assert ["10.0.0.1"] = Host.Static.dns()
    end

    test "uplink errors when unconfigured or blank; dns defaults to []" do
      Application.delete_env(:tank, Host.Static)
      assert {:error, :no_uplink_configured} = Host.Static.uplink()
      assert [] = Host.Static.dns()

      Application.put_env(:tank, Host.Static, uplink: "")
      assert {:error, :no_uplink_configured} = Host.Static.uplink()
    end
  end

  describe "facade" do
    test "defaults to Tank.Host.Static" do
      assert Host.adapter() == Host.Static
    end

    test "dispatches to the configured adapter" do
      original = Application.get_env(:tank, :host)
      Application.put_env(:tank, :host, StubAdapter)
      on_exit(fn -> Application.put_env(:tank, :host, original) end)

      assert {:ok, "stub0"} = Host.uplink()
      assert ["9.9.9.9"] = Host.dns()
    end
  end
end
