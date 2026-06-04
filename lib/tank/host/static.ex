defmodule Tank.Host.Static do
  @moduledoc """
  The default `Tank.Host`: uplink + DNS read straight from application config.
  Runs anywhere, with no host-network integration.

      config :tank, Tank.Host.Static,
        uplink: "eth0",
        dns: ["10.0.0.1"]

  `uplink/0` returns `{:error, :no_uplink_configured}` until `:uplink` is set, so
  a pod that uses `parent: :auto` fails clearly rather than silently. `dns/0`
  defaults to an empty list.
  """

  @behaviour Tank.Host

  @impl Tank.Host
  def uplink do
    case config()[:uplink] do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :no_uplink_configured}
    end
  end

  @impl Tank.Host
  def dns, do: List.wrap(config()[:dns])

  defp config, do: Application.get_env(:tank, __MODULE__, [])
end
