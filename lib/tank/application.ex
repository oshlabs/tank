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
    if store_enabled?(), do: [{Tank.Store, Application.get_env(:tank, :store, [])}], else: []
  end

  # Consumers (and the test suite) that manage the store themselves set
  # `config :tank, start_store?: false`.
  defp store_enabled?, do: Application.get_env(:tank, :start_store?, true)
end
