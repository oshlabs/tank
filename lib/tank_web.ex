defmodule TankWeb do
  @moduledoc """
  The entrypoint for Tank's web face — the admin UI living beside the domain
  in one OTP app (`lib/tank` + `lib/tank_web`, the stock Phoenix layout).

      use TankWeb, :live_view
      use TankWeb, :html

  The web layer is an adapter over the domain core: LiveViews call `Tank.*`
  directly, in-process, and contain zero orchestration logic. It renders
  [Gooey](https://github.com/oshlabs/gooey), the OSHLabs design system —
  components are imported per module below, stateful widgets stay aliased.

  Nothing here starts unless `config :tank, :web, enabled: true` — see
  `TankWeb.Supervisor` and the headless default in `Tank.Application`.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      # Gooey function components (per-module — there is no bundle import).
      import Gooey.Components.Badge
      import Gooey.Components.Button
      import Gooey.Components.Card
      import Gooey.Components.CodeBlock
      import Gooey.Components.DescriptionList
      import Gooey.Components.Divider
      import Gooey.Components.Dropdown
      import Gooey.Components.EmptyState
      import Gooey.Components.Icon
      import Gooey.Components.Input
      import Gooey.Components.Loading
      import Gooey.Components.Modal
      import Gooey.Components.Progress
      import Gooey.Components.Shell
      import Gooey.Components.Stat
      import Gooey.Components.StatusBar
      import Gooey.Components.Table
      import Gooey.Components.Tabs
      import Gooey.Components.Timeline
      import Gooey.Components.Tooltip

      # Stateful Gooey widgets (rendered via <.live_component module={...}>).
      alias Gooey.Components.{Chart, DataTable, Terminal}

      alias Phoenix.LiveView.JS
      alias TankWeb.Layouts

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: TankWeb.Endpoint,
        router: TankWeb.Router,
        statics: TankWeb.static_paths()
    end
  end

  @doc "When used, dispatch to the appropriate controller/live_view/etc."
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
