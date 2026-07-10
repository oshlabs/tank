defmodule Tank.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Tank.Supervisor]

    case Supervisor.start_link(children(), opts) do
      {:ok, sup} ->
        # The store child's init blocks until Khepri is ready, so by here the
        # store is up: seed the configured pods create-if-absent.
        if store_enabled?(), do: Tank.seed(Application.get_env(:tank, :pods, []))
        {:ok, sup}

      error ->
        error
    end
  end

  defp children do
    # The log/event registries run even with the store disabled: standalone
    # runtimes (tests, embedders driving Tank.Runtime directly) still
    # capture logs and broadcast events.
    logs_registry = {Registry, keys: :duplicate, name: Tank.Logs.registry()}
    events_registry = {Registry, keys: :duplicate, name: Tank.Events.registry()}

    if store_enabled?() do
      store_opts = Application.get_env(:tank, :store, [])

      # The network services attach to the store, and the reconciler reads
      # both, so the order is store → net → reconciler. Reconciler options
      # (interval, backoff, image cache via :runtime_opts) come from config.
      # The web face (when enabled) starts last: the domain is ready at the
      # first request.
      [logs_registry, events_registry, {Tank.Store, store_opts}] ++
        Tank.Net.child_specs(Application.get_env(:tank, :net), store_opts) ++
        [{Tank.Reconciler, Application.get_env(:tank, :reconciler, [])}] ++
        web_children()
    else
      [logs_registry, events_registry] ++ web_children()
    end
  end

  # Consumers (and the test suite) that manage the store themselves set
  # `config :tank, start_store?: false`.
  defp store_enabled?, do: Application.get_env(:tank, :start_store?, true)

  # The admin UI is opt-in (`config :tank, :web, enabled: true` — dev.exs, or
  # TANK_WEB=1 via runtime.exs). Absent → headless: no Phoenix process starts.
  defp web_children do
    if Application.get_env(:tank, :web, [])[:enabled], do: [TankWeb.Supervisor], else: []
  end
end
