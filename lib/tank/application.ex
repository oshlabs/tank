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
    # The log-subscription registry runs even with the store disabled:
    # standalone runtimes (tests, embedders driving Tank.Runtime directly)
    # still capture and broadcast logs.
    logs_registry = {Registry, keys: :duplicate, name: Tank.Logs.registry()}

    if store_enabled?() do
      store_opts = Application.get_env(:tank, :store, [])

      # The network services attach to the store, and the reconciler reads
      # both, so the order is store → net → reconciler. Reconciler options
      # (interval, backoff, image cache via :runtime_opts) come from config.
      [logs_registry, {Tank.Store, store_opts}] ++
        Tank.Net.child_specs(Application.get_env(:tank, :net), store_opts) ++
        [{Tank.Reconciler, Application.get_env(:tank, :reconciler, [])}]
    else
      [logs_registry]
    end
  end

  # Consumers (and the test suite) that manage the store themselves set
  # `config :tank, start_store?: false`.
  defp store_enabled?, do: Application.get_env(:tank, :start_store?, true)
end
