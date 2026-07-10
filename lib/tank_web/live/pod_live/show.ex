defmodule TankWeb.PodLive.Show do
  @moduledoc false
  use TankWeb, :live_view

  alias TankWeb.Status

  @tabs [
    {:overview, "Overview"},
    {:logs, "Logs"},
    {:terminal, "Terminal"},
    {:spec, "Spec"}
  ]

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Tank.get(name) do
      {:ok, pod} ->
        if connected?(socket), do: Process.send_after(self(), :refresh, 2_000)
        {:ok, socket |> assign(name: name, page_title: name) |> load(pod)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "no pod named #{inspect(name)}")
         |> push_navigate(to: ~p"/pods")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 2_000)

    case Tank.get(socket.assigns.name) do
      {:ok, pod} -> {:noreply, load(socket, pod)}
      {:error, :not_found} -> {:noreply, push_navigate(socket, to: ~p"/pods")}
    end
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Tank.delete(socket.assigns.name) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "pod #{socket.assigns.name} deleted")
         |> push_navigate(to: ~p"/pods")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "delete failed: #{inspect(reason)}")}
    end
  end

  defp load(socket, pod) do
    row = Enum.find(Status.rows(), &(&1.name == pod.name))
    status = if row, do: row.status, else: :pending
    retries = if row, do: row.retries, else: 0
    assign(socket, pod: pod, status: status, retries: retries)
  end

  defp tabs, do: @tabs

  defp tab_path(name, :overview), do: ~p"/pods/#{name}"
  defp tab_path(name, :logs), do: ~p"/pods/#{name}/logs"
  defp tab_path(name, :terminal), do: ~p"/pods/#{name}/terminal"
  defp tab_path(name, :spec), do: ~p"/pods/#{name}/spec"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} suite={@suite}>
      <:page_title>
        <span class="flex items-center gap-3">
          {@name}
          <.badge variant={TankWeb.Status.badge_color(@status)}>
            {@status}<span :if={@status == :backing_off}> · retry {@retries}</span>
          </.badge>
        </span>
      </:page_title>
      <:actions>
        <.button variant="ghost" disabled title="lands with Tank.restart/1">Restart</.button>
        <.button
          variant="error"
          phx-click="delete"
          data-confirm={"Delete pod #{@name}? The reconciler stops its workload."}
        >
          Delete
        </.button>
      </:actions>

      <nav class="tabs tabs-border mb-6" role="tablist">
        <.link
          :for={{tab, label} <- tabs()}
          patch={tab_path(@name, tab)}
          role="tab"
          class={["tab", @live_action == tab && "tab-active"]}
        >
          {label}
        </.link>
      </nav>

      <section :if={@live_action == :overview}>
        <.description_list>
          <:item label="Restart policy">{inspect(@pod.restart)}</:item>
          <:item label="Network">{network_summary(@pod)}</:item>
          <:item label="Containers">
            {@pod.containers |> Enum.map(&"#{&1.name} (#{image_ref(&1)})") |> Enum.join(", ")}
          </:item>
          <:item label="Volumes">
            {if @pod.volumes == [], do: "—", else: Enum.map_join(@pod.volumes, ", ", & &1.name)}
          </:item>
        </.description_list>
      </section>

      <section :if={@live_action == :logs}>
        <.empty_state
          icon="document-text"
          title="Log viewer coming up"
          message="Tank captures this pod's stdout/stderr already; the live viewer lands in the next slice."
        />
      </section>

      <section :if={@live_action == :terminal}>
        <.empty_state
          icon="terminal"
          title="Terminal coming up"
          message="Exec-a-shell and attach land with the console seam in the next slice."
        />
      </section>

      <section :if={@live_action == :spec}>
        <.code_block
          id="pod-spec"
          language="elixir"
          source={inspect(@pod, pretty: true, limit: :infinity)}
        />
      </section>
    </Layouts.app>
    """
  end

  defp network_summary(%Tank.Pod{network: :host}), do: "host"
  defp network_summary(%Tank.Pod{network: :none}), do: "none"

  defp network_summary(%Tank.Pod{network: %{nics: nics}}) when is_list(nics),
    do: Enum.map_join(nics, ", ", &"#{&1.name} (#{&1.mode})")

  defp network_summary(_), do: "—"

  defp image_ref(%{image: {:rootfs, path}}), do: "rootfs:#{path}"
  defp image_ref(%{image: ref}), do: ref
end
