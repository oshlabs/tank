defmodule TankWeb.Supervisor do
  @moduledoc """
  The web face's supervision tree — telemetry, PubSub, endpoint.

  Started by `Tank.Application` only when `config :tank, :web, enabled: true`;
  with the key absent Tank boots headless and no Phoenix process exists. The
  whole web tree hangs off this one module, so extracting `tank_web` back out
  of the repo (the recorded escape hatch) stays mechanical.

  Requires the store branch: the UI is meaningless without desired state, so
  booting with `:web` enabled and `start_store?: false` raises early with a
  clear message rather than rendering screens over nothing.
  """

  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    unless Application.get_env(:tank, :start_store?, true) do
      raise """
      config :tank, :web is enabled but the store is disabled
      (start_store?: false). The web UI reads desired state from the store;
      enable it, or drop the :web config to run headless.
      """
    end

    check_node_modules!()

    children = [
      TankWeb.Telemetry,
      {Phoenix.PubSub, name: Tank.PubSub},
      TankWeb.Endpoint
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # `mix phx.server` straight after `mix deps.get` drowns the log in esbuild
  # "Could not resolve @wterm/…" noise because the npm step only runs via
  # `mix setup`. Fail loudly with the actual instruction instead. Dev-only
  # (config :tank, :web, check_node_modules: true).
  defp check_node_modules! do
    if Application.get_env(:tank, :web, [])[:check_node_modules] &&
         not File.dir?(Path.join(File.cwd!(), "assets/node_modules/@wterm")) do
      raise """
      assets/node_modules is missing (or incomplete) — the asset watchers
      cannot build tank_web without it. Run once from tank/:

          mix setup

      (or just the missing step: npm install --prefix assets)
      """
    end
  end
end
