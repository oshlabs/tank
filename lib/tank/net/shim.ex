defmodule Tank.Net.Shim do
  @moduledoc """
  The host-side service interface on a pod network (see `docs/networking.md`).

  macvlan pods cannot reach the host over the shared parent — the kernel drops
  that hairpin by design — so the host joins the pool through its own macvlan
  child. That interface is what makes the embedded DNS listener reachable from
  pods, and what gives the host (health checks, tank_web's reverse proxy
  later) a route to its pods at all.

  `ensure/1` is idempotent: create-or-adopt the link, bring it up, add the
  address. The shim is never torn down on stop — level-triggered, adopted on
  the next boot.
  """

  alias Linx.Netlink.{Rtnl, Socket}
  alias Linx.Netlink.Rtnl.{Address, Link}

  @typedoc "Everything needed to actuate the shim, already resolved."
  @type spec :: %{name: String.t(), parent: String.t(), ip: String.t(), prefix: 0..32}

  @doc "Create-or-adopt the shim link in the host netns, up + addressed."
  @spec ensure(spec) :: :ok | {:error, term}
  def ensure(%{name: name, parent: parent, ip: ip, prefix: prefix}) do
    with {:ok, sock} <- Rtnl.open() do
      try do
        with :ok <- create(sock, name, parent),
             :ok <- Link.set_up(sock, name) do
          add_address(sock, name, ip, prefix)
        end
      after
        Socket.close(sock)
      end
    end
  end

  defp create(sock, name, parent) do
    case Link.create_macvlan(sock, name, parent, :bridge) do
      :ok -> :ok
      # Already there (previous boot / restart): adopt it.
      {:error, :eexist} -> :ok
      {:error, _} = err -> err
    end
  end

  defp add_address(sock, name, ip, prefix) do
    case Address.add(sock, name, ip, prefix) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} = err -> err
    end
  end
end
