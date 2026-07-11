defmodule TankWeb.PodLive.Show do
  @moduledoc false
  use TankWeb, :live_view

  alias Gooey.Components.LogViewer
  alias TankWeb.Status

  @tabs [
    {:overview, "Overview"},
    {:logs, "Logs"},
    {:terminal, "Terminal"},
    {:spec, "Spec"}
  ]

  # header sparkline / overview chart windows (ms)
  @spark_window :timer.minutes(2)
  @chart_window :timer.minutes(5)

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Tank.status(name) do
      {:ok, row} ->
        if connected?(socket) do
          Tank.Events.subscribe(:pods)
          Tank.Logs.subscribe(name)
          Tank.Stats.subscribe(name)
        end

        {:ok, seed} = Tank.logs(name, tail: 500)

        {:ok,
         socket
         |> assign(
           name: name,
           page_title: name,
           log_seed: Enum.map(seed, &log_line/1),
           pending_logs: [],
           log_flush_queued: false,
           sample: current_sample(name),
           session: nil,
           session_label: nil,
           term_size: {80, 24},
           term_buffer: [],
           term_buffered: 0,
           exec_cmd: "/bin/sh"
         )
         |> assign_row(row)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "no pod named #{inspect(name)}")
         |> push_navigate(to: ~p"/pods")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # === live updates =========================================================

  @impl true
  def handle_info({:tank_event, :pods, %{name: name} = payload}, socket) do
    cond do
      name != socket.assigns.name ->
        {:noreply, socket}

      payload.status == :deleted ->
        {:noreply,
         socket
         |> put_flash(:info, "pod #{name} was deleted")
         |> push_navigate(to: ~p"/pods")}

      true ->
        case Tank.status(name) do
          {:ok, row} -> {:noreply, assign_row(socket, row)}
          {:error, :not_found} -> {:noreply, socket}
        end
    end
  end

  def handle_info({:tank_event, {:stats, _pod}, sample}, socket) do
    t = DateTime.to_unix(sample.at, :millisecond)

    push_metric("spark-cpu", "cpu", t, sample.cpu_percent)
    push_metric("spark-mem", "mem", t, sample.memory_bytes)
    push_metric("spark-rx", "rx", t, sample.rx_bytes_per_sec)
    push_metric("spark-tx", "tx", t, sample.tx_bytes_per_sec)
    push_metric("chart-cpu", "cpu", t, sample.cpu_percent)
    push_metric("chart-mem", "mem", t, sample.memory_bytes)

    {:noreply, assign(socket, sample: sample)}
  end

  # Log lines: coalesce bursts into one append per 100ms.
  def handle_info({:tank_logs, name, entry}, %{assigns: %{name: name}} = socket) do
    socket = update(socket, :pending_logs, &[log_line(entry) | &1])

    if socket.assigns.log_flush_queued do
      {:noreply, socket}
    else
      Process.send_after(self(), :flush_logs, 100)
      {:noreply, assign(socket, log_flush_queued: true)}
    end
  end

  def handle_info(:flush_logs, socket) do
    lines = Enum.reverse(socket.assigns.pending_logs)

    if lines != [],
      do: send_update(LogViewer, id: log_viewer_id(socket.assigns.name), append: lines)

    {:noreply, assign(socket, pending_logs: [], log_flush_queued: false)}
  end

  # A chart hook mounted: seed it from the stats ring.
  def handle_info({:gooey_chart, id, :ready}, socket) do
    seed_chart(socket.assigns.name, id)
    {:noreply, socket}
  end

  def handle_info({:gooey_chart, _id, _event}, socket), do: {:noreply, socket}

  # Terminal hook events. On (re)mount, replay the session's scrollback —
  # the hook may have missed bytes that raced its async init, and a tab
  # switch remounts it fresh.
  def handle_info({:gooey_terminal, _id, :ready}, socket) do
    if socket.assigns.term_buffer != [] do
      send_update(Gooey.Components.Terminal,
        id: term_id(socket.assigns.name),
        write: Enum.reverse(socket.assigns.term_buffer)
      )
    end

    {:noreply, socket}
  end

  def handle_info({:gooey_terminal, _id, {:input, data}}, socket) do
    if socket.assigns.session, do: Tank.Console.write(socket.assigns.session, data)
    {:noreply, socket}
  end

  def handle_info({:gooey_terminal, _id, {:resize, cols, rows}}, socket) do
    if socket.assigns.session, do: Tank.Console.resize(socket.assigns.session, cols, rows)
    {:noreply, assign(socket, term_size: {cols, rows})}
  end

  # Console session events.
  def handle_info({:tank_console, session, msg}, %{assigns: %{session: session}} = socket) do
    case msg do
      {:data, bytes} ->
        send_update(Gooey.Components.Terminal, id: term_id(socket.assigns.name), write: bytes)
        {:noreply, buffer_term(socket, bytes)}

      {:exit, reason} ->
        banner = "\r\n\e[2m[session ended: #{exit_text(reason)}]\e[0m\r\n"
        send_update(Gooey.Components.Terminal, id: term_id(socket.assigns.name), write: banner)
        {:noreply, socket |> buffer_term(banner) |> assign(session: nil, session_label: nil)}

      :closed ->
        {:noreply, assign(socket, session: nil, session_label: nil)}
    end
  end

  # A stale console session (already replaced/closed) — ignore.
  def handle_info({:tank_console, _session, _msg}, socket), do: {:noreply, socket}
  def handle_info({:gooey_log_viewer, _id, _event}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # === actions ==============================================================

  @impl true
  def handle_event("restart", _params, socket) do
    case Tank.restart(socket.assigns.name) do
      :ok ->
        {:noreply, put_flash(socket, :info, "restarting #{socket.assigns.name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "restart failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", _params, socket) do
    case Tank.delete(socket.assigns.name) do
      :ok ->
        {:noreply, push_navigate(socket, to: ~p"/pods")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("exec", %{"cmd" => cmd}, socket) do
    {cols, rows} = socket.assigns.term_size
    argv = cmd |> String.trim() |> String.split(~r/\s+/)

    case Tank.Console.exec(socket.assigns.name, argv, cols: cols, rows: rows) do
      {:ok, session} ->
        {:noreply,
         assign(socket,
           session: session,
           session_label: "exec: #{cmd}",
           exec_cmd: cmd,
           term_buffer: [],
           term_buffered: 0
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "exec failed: #{inspect(reason)}")}
    end
  end

  def handle_event("attach", _params, socket) do
    {cols, rows} = socket.assigns.term_size

    case Tank.Console.attach(socket.assigns.name, cols: cols, rows: rows) do
      {:ok, session} ->
        {:noreply,
         assign(socket,
           session: session,
           session_label: "attached to main process",
           term_buffer: [],
           term_buffered: 0
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "attach failed: #{inspect(reason)}")}
    end
  end

  def handle_event("disconnect", _params, socket) do
    if socket.assigns.session, do: Tank.Console.close(socket.assigns.session)
    {:noreply, assign(socket, session: nil, session_label: nil)}
  end

  # === helpers ==============================================================

  defp assign_row(socket, row) do
    assign(socket,
      pod: row.pod,
      status: row.status,
      retries: row.retries,
      last_exit: row.last_exit,
      started_at: row.started_at,
      addresses: Status.addresses(row.pod),
      dns: Status.dns_name(row.pod.name),
      tty?: Enum.any?(row.pod.containers, & &1.tty)
    )
  end

  defp current_sample(name) do
    case Tank.stats(name) do
      {:ok, sample} -> sample
      _ -> nil
    end
  end

  defp seed_chart(name, id) do
    {window, metric} =
      case id do
        "spark-" <> m -> {@spark_window, m}
        "chart-" <> m -> {@chart_window, m}
        _ -> {nil, nil}
      end

    if metric do
      points =
        for s <- Tank.stats(name, window: window),
            value = metric_value(s, metric),
            do: [DateTime.to_unix(s.at, :millisecond), value]

      send_update(Chart, id: id, set_series: [%{id: metric, data: points}])
    end
  end

  defp metric_value(s, "cpu"), do: s.cpu_percent
  defp metric_value(s, "mem"), do: s.memory_bytes
  defp metric_value(s, "rx"), do: s.rx_bytes_per_sec
  defp metric_value(s, "tx"), do: s.tx_bytes_per_sec
  defp metric_value(_s, _metric), do: nil

  defp push_metric(_chart_id, _sid, _t, nil), do: :ok

  defp push_metric(chart_id, sid, t, value),
    do: Chart.push_points(chart_id, %{t: t, values: %{sid => value}})

  defp log_line(entry) do
    %{
      ts: entry.ts,
      source: entry.container,
      tag: to_string(entry.stream),
      text: entry.line
    }
  end

  # Session scrollback, capped: chunks kept newest-first, oldest dropped.
  @term_scrollback_cap 65_536
  defp buffer_term(socket, bytes) do
    {oldest_first, total} =
      trim_term(
        Enum.reverse([bytes | socket.assigns.term_buffer]),
        socket.assigns.term_buffered + byte_size(bytes)
      )

    assign(socket, term_buffer: Enum.reverse(oldest_first), term_buffered: total)
  end

  defp trim_term([oldest | rest], total) when total > @term_scrollback_cap,
    do: trim_term(rest, total - byte_size(oldest))

  defp trim_term(buffer, total), do: {buffer, total}

  defp log_viewer_id(name), do: "logs-#{name}"
  defp term_id(name), do: "term-#{name}"

  defp exit_text({:exited, code}), do: "exited #{code}"
  defp exit_text({:signaled, signum}), do: "killed by signal #{signum}"
  defp exit_text({:error, reason}), do: "error: #{inspect(reason)}"

  defp tabs, do: @tabs

  defp tab_path(name, :overview), do: ~p"/pods/#{name}"
  defp tab_path(name, :logs), do: ~p"/pods/#{name}/logs"
  defp tab_path(name, :terminal), do: ~p"/pods/#{name}/terminal"
  defp tab_path(name, :spec), do: ~p"/pods/#{name}/spec"

  defp network_summary(%Tank.Pod{network: :host}), do: "host"
  defp network_summary(%Tank.Pod{network: :none}), do: "none"

  defp network_summary(%Tank.Pod{network: %{nics: nics}}) when is_list(nics),
    do: Enum.map_join(nics, ", ", &"#{&1.name} (#{&1.mode})")

  defp network_summary(_), do: "—"

  defp image_ref(%{image: {:rootfs, path}}), do: "rootfs:#{path}"
  defp image_ref(%{image: ref}), do: ref

  # === render ===============================================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} suite={@suite}>
      <:page_title>
        <span class="flex items-center gap-3">
          {@name}
          <.badge variant={Status.badge_color(@status)}>{@status}</.badge>
          <span :if={@status == :backing_off} class="text-xs opacity-60">
            retry {@retries} · {Status.exit_label(@last_exit)}
          </span>
          <span :if={@status == :terminal and @last_exit} class="text-xs opacity-60">
            {Status.exit_label(@last_exit)}
          </span>
        </span>
      </:page_title>
      <:actions>
        <.button variant="ghost" phx-click="restart" data-confirm={"Restart pod #{@name}?"}>
          Restart
        </.button>
        <.button
          variant="error"
          phx-click="delete"
          data-confirm={"Delete pod #{@name}? The reconciler stops its workload."}
        >
          Delete
        </.button>
      </:actions>

      <div class="flex items-center gap-2 mb-4 text-sm">
        <span :for={addr <- @addresses} class="font-mono badge badge-ghost badge-sm">
          {addr.nic}: {addr.ip}
        </span>
        <span :if={@dns && @addresses != []} class="font-mono opacity-60">{@dns}</span>
        <span class="opacity-60 ml-auto">up {Status.age(@started_at)}</span>
      </div>

      <.stat_group class="mb-6" surface="base-200">
        <.stat label="CPU" value={Status.percent(@sample && @sample.cpu_percent)} size="sm">
          <:figure>
            <.live_component
              module={Chart}
              id="spark-cpu"
              type="sparkline"
              streaming?
              window_ms={120_000}
              series={[%{id: "cpu", data: []}]}
              class="w-24 h-8"
            />
          </:figure>
        </.stat>
        <.stat label="Memory" value={Status.bytes(@sample && @sample.memory_bytes)} size="sm">
          <:figure>
            <.live_component
              module={Chart}
              id="spark-mem"
              type="sparkline"
              streaming?
              window_ms={120_000}
              series={[%{id: "mem", data: []}]}
              class="w-24 h-8"
            />
          </:figure>
        </.stat>
        <.stat label="RX" value={Status.rate(@sample && @sample.rx_bytes_per_sec)} size="sm">
          <:figure>
            <.live_component
              module={Chart}
              id="spark-rx"
              type="sparkline"
              streaming?
              window_ms={120_000}
              series={[%{id: "rx", data: []}]}
              class="w-24 h-8"
            />
          </:figure>
        </.stat>
        <.stat label="TX" value={Status.rate(@sample && @sample.tx_bytes_per_sec)} size="sm">
          <:figure>
            <.live_component
              module={Chart}
              id="spark-tx"
              type="sparkline"
              streaming?
              window_ms={120_000}
              series={[%{id: "tx", data: []}]}
              class="w-24 h-8"
            />
          </:figure>
        </.stat>
        <.stat label="PIDs" value={(@sample && @sample.pids) || "—"} size="sm" />
        <.stat label="Restarts" value={@retries} size="sm" />
      </.stat_group>

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

      <section :if={@live_action == :overview} class="flex flex-col gap-6">
        <div class="grid gap-4 lg:grid-cols-2">
          <.live_component
            module={Chart}
            id="chart-cpu"
            type="area"
            streaming?
            window_ms={300_000}
            title="CPU"
            series={[%{id: "cpu", label: "CPU", data: []}]}
            y_axis={%{min: 0, unit: "%"}}
            x_axis={%{type: "time", format: "clock"}}
            class="h-56"
          />
          <.live_component
            module={Chart}
            id="chart-mem"
            type="area"
            streaming?
            window_ms={300_000}
            title="Memory"
            series={[%{id: "mem", label: "Memory", data: []}]}
            y_axis={%{min: 0, format: "si"}}
            x_axis={%{type: "time", format: "clock"}}
            class="h-56"
          />
        </div>

        <.description_list>
          <:item label="Restart policy">{inspect(@pod.restart)}</:item>
          <:item label="Network">{network_summary(@pod)}</:item>
          <:item label="Containers">
            {@pod.containers |> Enum.map(&"#{&1.name} (#{image_ref(&1)})") |> Enum.join(", ")}
          </:item>
          <:item label="Volumes">
            {if @pod.volumes == [], do: "—", else: Enum.map_join(@pod.volumes, ", ", & &1.name)}
          </:item>
          <:item :if={@last_exit} label="Last exit">
            {Status.exit_label(@last_exit)}
          </:item>
        </.description_list>
      </section>

      <%!-- Logs and Terminal stay mounted across tab switches (hidden, not
           removed): the log ring and the console session survive. --%>
      <section class={["grow min-h-0", @live_action != :logs && "hidden"]}>
        <.live_component
          module={LogViewer}
          id={log_viewer_id(@name)}
          lines={@log_seed}
          class="h-[65vh]"
        />
      </section>

      <section :if={@live_action == :terminal}>
        <div :if={@session == nil} class="grid gap-4 lg:grid-cols-2 mb-4">
          <.card>
            <:header>New shell</:header>
            <form phx-submit="exec" class="flex gap-2 items-end">
              <.input name="cmd" label="Command" value={@exec_cmd} class="font-mono grow" />
              <.button type="submit" variant="primary" disabled={@status != :running}>
                Exec
              </.button>
            </form>
            <p :if={@status != :running} class="text-xs opacity-60 mt-2">
              The pod must be running.
            </p>
          </.card>
          <.card>
            <:header>Attach to main process</:header>
            <p class="text-sm opacity-70 mb-3">
              Take over the pod's main PTY (requires a <code>tty: true</code> container).
              Output during the attach still reaches the log.
            </p>
            <.button phx-click="attach" disabled={not @tty? or @status != :running}>
              Attach
            </.button>
          </.card>
        </div>

        <div :if={@session} class="flex items-center gap-3 mb-2 text-sm">
          <.badge variant="info">{@session_label}</.badge>
          <.button size="sm" variant="ghost" phx-click="disconnect">Disconnect</.button>
        </div>

        <.live_component
          module={Gooey.Components.Terminal}
          id={term_id(@name)}
          class={["h-[60vh] w-full", @session == nil && "opacity-70"]}
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
end
