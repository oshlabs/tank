defmodule TankWeb.NetworkLive.Index do
  @moduledoc false
  use TankWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Networks", pools: pools())}
  end

  # Read-only Advanced view over the Starfish-in-Tank services. Pools come
  # from the IPAM; allocations per pool land in the next slice.
  defp pools do
    if Tank.Net.enabled?() do
      Starfish.IPAM.list_prefixes()
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} suite={@suite}>
      <:page_title>Networks</:page_title>

      <.empty_state
        :if={@pools == []}
        icon="flow"
        title="No pools declared"
        message="Declare IPAM pools under config :tank, :net — pod NICs draw addresses from them."
      />

      <div :if={@pools != []} class="grid gap-4 lg:grid-cols-2">
        <.card :for={pool <- @pools}>
          <:header>{inspect(pool)}</:header>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
