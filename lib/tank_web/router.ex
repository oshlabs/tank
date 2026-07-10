defmodule TankWeb.Router do
  use TankWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {TankWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", TankWeb do
    pipe_through(:browser)

    live_session :default, on_mount: [{TankWeb.Nav, :default}] do
      # Containers-first: "/" IS the pod list.
      live("/", PodLive.Index, :index)
      live("/pods", PodLive.Index, :index)
      live("/pods/:name", PodLive.Show, :overview)
      live("/pods/:name/logs", PodLive.Show, :logs)
      live("/pods/:name/terminal", PodLive.Show, :terminal)
      live("/pods/:name/spec", PodLive.Show, :spec)
      live("/networks", NetworkLive.Index, :index)
      live("/system", SystemLive.Index, :index)
    end
  end
end
