defmodule TankWeb.NetworkLive.Index do
  @moduledoc false
  use TankWeb, :live_view

  # Read-only Advanced view over the Starfish-in-Tank network services:
  # IPAM pools with their live allocations, plus the DNS/shim facts. CRUD
  # lands with the network milestone (m2); this screen is its skeleton.

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tank.Events.subscribe(:pods)
    {:ok, socket |> assign(page_title: "Networks") |> refresh()}
  end

  # Allocations follow pod lifecycles; any pod event refreshes the view.
  @impl true
  def handle_info({:tank_event, :pods, _payload}, socket) do
    Process.send_after(self(), :refresh, 300)
    {:noreply, socket}
  end

  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    assign(socket, pools: pools(), dns: dns_facts())
  end

  defp pools do
    if Tank.Net.enabled?() do
      for prefix <- Starfish.IPAM.list_prefixes() do
        subnet = "#{Starfish.IP.to_string(prefix.subnet.address)}/#{prefix.subnet.prefix}"

        %{
          subnet: subnet,
          gateway: prefix.gateway && Starfish.IP.to_string(prefix.gateway),
          dns: Enum.map(prefix.dns, &Starfish.IP.to_string/1),
          allocations: allocations(prefix.subnet)
        }
      end
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp allocations(subnet) do
    for alloc <- Starfish.IPAM.list_allocations(subnet) do
      %{
        ip: Starfish.IP.to_string(alloc.ip),
        hostname: alloc.hostname,
        status: alloc.status,
        client: client_label(alloc.client)
      }
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp client_label({:tank_pod, pod, nic}), do: {:pod, pod, nic}
  defp client_label({:tank_host, :shim}), do: {:other, "host shim"}
  defp client_label(other), do: {:other, inspect(other)}

  defp dns_facts do
    net = Application.get_env(:tank, :net) || []

    case Keyword.get(net, :dns, []) do
      false ->
        nil

      dns ->
        %{
          origin: Keyword.get(dns, :origin, "tank.internal"),
          ips: safe_dns_ips()
        }
    end
  end

  defp safe_dns_ips do
    Tank.Net.dns_ips()
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

      <div :if={@pools != []} class="flex flex-col gap-6">
        <.card :if={@dns}>
          <:header>DNS</:header>
          <.description_list>
            <:item label="Origin">{@dns.origin}</:item>
            <:item label="Listeners">
              {if @dns.ips == [], do: "—", else: Enum.join(@dns.ips, ", ")}
            </:item>
          </.description_list>
        </.card>

        <.card :for={pool <- @pools}>
          <:header>
            <span class="font-mono">{pool.subnet}</span>
          </:header>
          <.description_list class="mb-4">
            <:item label="Gateway">{pool.gateway || "—"}</:item>
            <:item label="DNS">{if pool.dns == [], do: "—", else: Enum.join(pool.dns, ", ")}</:item>
            <:item label="Allocations">{length(pool.allocations)}</:item>
          </.description_list>

          <.table :if={pool.allocations != []} id={"alloc-#{pool.subnet}"} rows={pool.allocations}>
            <:col :let={a} label="IP"><span class="font-mono">{a.ip}</span></:col>
            <:col :let={a} label="Hostname">{a.hostname || "—"}</:col>
            <:col :let={a} label="Client">
              <%= case a.client do %>
                <% {:pod, pod, nic} -> %>
                  <.link navigate={~p"/pods/#{pod}"} class="link">{pod}</.link>
                  <span class="opacity-60 text-xs ml-1">{nic}</span>
                <% {:other, label} -> %>
                  {label}
              <% end %>
            </:col>
            <:col :let={a} label="Status">
              <.badge variant={if a.status == :active, do: "success", else: "neutral"} size="sm">
                {a.status}
              </.badge>
            </:col>
          </.table>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
