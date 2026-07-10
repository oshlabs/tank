defmodule TankWeb.PodLive.Index do
  @moduledoc false
  use TankWeb, :live_view

  alias TankWeb.Status

  @impl true
  def mount(_params, _session, socket) do
    rows = Status.rows()

    # Interim refresh: poll until Tank.Events lands (Phase B), then subscribe.
    if connected?(socket), do: Process.send_after(self(), :refresh, 2_000)

    {:ok, assign(socket, rows: rows, counts: Status.counts(rows), page_title: "Pods")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 2_000)
    rows = Status.rows()
    {:noreply, assign(socket, rows: rows, counts: Status.counts(rows))}
  end

  @impl true
  def handle_event("delete", %{"name" => name}, socket) do
    case Tank.delete(name) do
      :ok ->
        rows = Status.rows()
        {:noreply, assign(socket, rows: rows, counts: Status.counts(rows))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} suite={@suite}>
      <:page_title>Pods</:page_title>

      <.stat_group class="mb-6">
        <.stat label="Running" value={Map.get(@counts, :running, 0)} />
        <.stat label="Backing off" value={Map.get(@counts, :backing_off, 0)} />
        <.stat label="Terminal" value={Map.get(@counts, :terminal, 0)} />
        <.stat label="Declared" value={length(@rows)} />
      </.stat_group>

      <.empty_state
        :if={@rows == []}
        icon="shapes"
        title="No pods declared"
        message="Declare your first pod with Tank.apply/1 — the apply form lands with the next slice."
      />

      <.table :if={@rows != []} id="pods" rows={@rows} row_click={&JS.navigate(~p"/pods/#{&1.name}")}>
        <:col :let={row} label="Name">{row.name}</:col>
        <:col :let={row} label="Status">
          <.badge variant={TankWeb.Status.badge_color(row.status)}>{row.status}</.badge>
        </:col>
        <:col :let={row} label="Containers">
          {row.pod.containers |> Enum.map(& &1.name) |> Enum.join(", ")}
        </:col>
        <:col :let={row} label="Restarts">{row.retries}</:col>
        <:action :let={row}>
          <.button size="sm" variant="ghost" phx-click="delete" phx-value-name={row.name}>
            Delete
          </.button>
        </:action>
      </.table>
    </Layouts.app>
    """
  end
end
