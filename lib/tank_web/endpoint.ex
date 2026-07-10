defmodule TankWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :tank

  # Cookie-signed session. No auth yet (localhost-bound); the session plumbing
  # is in place for the login milestone (Khepri-subtree users per the plan).
  @session_options [
    store: :cookie,
    key: "_tank_key",
    signing_salt: "kYqLxR2m",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Static,
    at: "/",
    from: :tank,
    gzip: not code_reloading?,
    only: TankWeb.static_paths(),
    raise_on_missing_only: code_reloading?
  )

  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(TankWeb.Router)
end
