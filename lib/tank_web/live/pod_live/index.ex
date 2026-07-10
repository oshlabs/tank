defmodule TankWeb.PodLive.Index do
  @moduledoc false
  use TankWeb, :live_view

  alias TankWeb.Status

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tank.Events.subscribe(:pods)

    {:ok,
     socket
     |> assign(page_title: "Pods", refresh_queued: false, apply_open: false, apply_error: nil)
     |> refresh()}
  end

  # Any pod event → coalesced re-read (bursts of transitions cost one read).
  @impl true
  def handle_info({:tank_event, :pods, _payload}, socket) do
    if socket.assigns.refresh_queued do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh, 150)
      {:noreply, assign(socket, refresh_queued: true)}
    end
  end

  def handle_info(:refresh, socket) do
    {:noreply, socket |> assign(refresh_queued: false) |> refresh()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"name" => name}, socket) do
    case Tank.delete(name) do
      :ok ->
        {:noreply, refresh(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("open-apply", _params, socket),
    do: {:noreply, assign(socket, apply_open: true, apply_error: nil)}

  def handle_event("close-apply", _params, socket),
    do: {:noreply, assign(socket, apply_open: false, apply_error: nil)}

  def handle_event("apply", %{"spec" => spec}, socket) do
    case parse_and_apply(spec) do
      :ok ->
        {:noreply,
         socket
         |> assign(apply_open: false, apply_error: nil)
         |> put_flash(:info, "pod applied")
         |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, apply_error: reason)}
    end
  end

  defp refresh(socket) do
    rows = Status.rows()
    assign(socket, rows: rows, counts: Status.counts(rows))
  end

  # The apply form takes a pod spec as an Elixir map literal — the same shape
  # Tank.apply/1 documents. Evaluated with zero bindings; this is the local
  # admin's own console (auth lands before any remote exposure).
  defp parse_and_apply(spec_text) do
    case Code.string_to_quoted(spec_text) do
      {:ok, quoted} ->
        if literal?(quoted) do
          {value, _} = Code.eval_quoted(quoted)
          Tank.apply(value)
        else
          {:error, "spec must be a literal map — no calls or variables"}
        end

      {:error, {meta, message, token}} ->
        {:error, "syntax error at line #{Keyword.get(meta, :line, "?")}: #{message}#{token}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Literal maps/lists/tuples/atoms/numbers/strings only — a data spec, not code.
  defp literal?({:%{}, _, pairs}), do: Enum.all?(pairs, &literal?/1)
  defp literal?({:{}, _, items}), do: Enum.all?(items, &literal?/1)
  defp literal?({a, b}), do: literal?(a) and literal?(b)
  defp literal?(list) when is_list(list), do: Enum.all?(list, &literal?/1)
  defp literal?(value) when is_atom(value) or is_number(value) or is_binary(value), do: true
  defp literal?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} suite={@suite}>
      <:page_title>Pods</:page_title>
      <:actions>
        <.button id="apply-pod" variant="primary" phx-click="open-apply">Apply pod</.button>
      </:actions>

      <.stat_group class="mb-6">
        <.stat label="Running" value={Map.get(@counts, :running, 0)} color="success" />
        <.stat label="Starting" value={Map.get(@counts, :starting, 0)} color="info" />
        <.stat label="Backing off" value={Map.get(@counts, :backing_off, 0)} color="warning" />
        <.stat label="Terminal" value={Map.get(@counts, :terminal, 0)} color="error" />
        <.stat label="Declared" value={length(@rows)} />
      </.stat_group>

      <.empty_state
        :if={@rows == []}
        icon="shapes"
        title="No pods declared"
        message="Apply your first pod — it converges the moment it's declared."
      >
        <:actions>
          <.button variant="primary" phx-click="open-apply">Apply pod</.button>
        </:actions>
      </.empty_state>

      <.table
        :if={@rows != []}
        id="pods"
        rows={@rows}
        row_click={&JS.navigate(~p"/pods/#{&1.pod.name}")}
      >
        <:col :let={row} label="Name">
          <span class="font-medium">{row.pod.name}</span>
        </:col>
        <:col :let={row} label="Status">
          <.badge variant={Status.badge_color(row.status)}>{row.status}</.badge>
          <span :if={row.status == :backing_off} class="text-xs opacity-60 ml-1">
            retry {row.retries}
          </span>
        </:col>
        <:col :let={row} label="Containers">
          {row.pod.containers |> Enum.map(& &1.name) |> Enum.join(", ")}
        </:col>
        <:col :let={row} label="Addresses">
          <span :for={addr <- Status.addresses(row.pod)} class="mr-2 font-mono text-xs">
            {addr.ip}
          </span>
        </:col>
        <:col :let={row} label="Restarts">{row.retries}</:col>
        <:col :let={row} label="Age">{Status.age(row.started_at)}</:col>
        <:action :let={row}>
          <.button
            size="sm"
            variant="ghost"
            phx-click="delete"
            phx-value-name={row.pod.name}
            data-confirm={"Delete pod #{row.pod.name}?"}
          >
            Delete
          </.button>
        </:action>
      </.table>

      <.modal :if={@apply_open} id="apply-modal" show on_cancel={JS.push("close-apply")}>
        <h3 class="text-lg font-semibold mb-4">Apply a pod</h3>
        <form phx-submit="apply" class="flex flex-col gap-4">
          <.input
            type="textarea"
            name="spec"
            label="Pod spec (Elixir map)"
            value={default_spec()}
            rows="12"
            class="font-mono text-sm"
          />
          <.alert :if={@apply_error} variant="error">{@apply_error}</.alert>
          <div class="flex justify-end gap-2">
            <.button type="button" variant="ghost" phx-click="close-apply">Cancel</.button>
            <.button type="submit" variant="primary">Apply</.button>
          </div>
        </form>
      </.modal>
    </Layouts.app>
    """
  end

  defp default_spec do
    ~S(%{
  name: "web",
  containers: [
    %{name: "app", image: "nginx:1.27"}
  ]
})
  end
end
