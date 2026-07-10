defmodule TankWeb.Nav do
  @moduledoc """
  Shared `on_mount` hook: tracks the current path across patches and builds
  the `Gooey.SuiteConfig` the app shell renders. Nav is assembled here — one
  place — so later sections (Interfaces, Firewall, Services, Tapps, Nodes)
  slot in without touching screens.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    socket =
      attach_hook(socket, :tank_nav, :handle_params, fn _params, url, socket ->
        path = URI.parse(url).path || "/"
        {:cont, assign(socket, :suite, suite_config(path))}
      end)

    {:cont, assign(socket, :suite, suite_config("/"))}
  end

  defp suite_config(current_path) do
    Gooey.SuiteConfig.new(
      brand: %{name: "Tank", home_path: "/pods"},
      current_path: normalize(current_path),
      nav: [
        %{label: "Pods", path: "/pods", icon: "shapes", section: "Workloads"},
        %{label: "Networks", path: "/networks", icon: "flow", section: "Network"},
        %{label: "System", path: "/system", icon: "cog", section: "System"}
      ]
    )
  end

  # "/" is the pod list; highlight the Pods item for it.
  defp normalize("/"), do: "/pods"
  defp normalize(path), do: path
end
