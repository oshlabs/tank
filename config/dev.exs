import Config

# Dev turns the web face on (the library default is off — headless). Real
# container actuation needs root: use ./sudoweb.sh; a plain `mix phx.server`
# still boots and renders (pods just fail to converge without privileges).
config :tank, :web, enabled: true, check_node_modules: true

config :tank, TankWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4400],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  # gooey is a path dependency developed alongside tank; reload it too so
  # changed components show up without restarting the server.
  reloadable_apps: [:gooey, :tank],
  secret_key_base: "qwOcMBst4B9dZKfW3M+lTLXYndOs/xTgh8XqXhqNJmqbnAdZbxLoUJey2HYRq44K",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:tank, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:tank, ~w(--watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"lib/tank_web/router\.ex$"E,
      ~r"lib/tank_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

# Do not include metadata nor timestamps in development logs.
config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
