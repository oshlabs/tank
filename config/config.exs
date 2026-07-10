import Config

# Compile-time operational defaults. *Desired* state (which pods) is seeded at
# runtime — see config/runtime.exs.

# Whether the application supervisor starts (and owns) a Khepri store. Consumers
# that run their own store, and the test suite, set this to false.
config :tank, start_store?: true

# The host-config adapter (uplink + DNS facts). The default reads them from
# config; a consumer swaps in its own. See `Tank.Host`.
config :tank, host: Tank.Host.Static

# Starfish runs embedded: Tank starts the IPAM stack itself (see `Tank.Ipam`),
# attached to Tank's own Khepri store — Starfish's own application supervisor
# must stay off. Pools are declared under `config :tank, :ipam` (runtime.exs).
config :starfish, start?: false

# Reconciler restart backoff: the first restart waits `backoff_base`, doubling
# on repeated rapid failures up to `backoff_cap`. A run that lasts `stable_window`
# resets the doubling back to `backoff_base`. The in-code defaults are
# `backoff_base: :timer.seconds(10)` (matching Kubernetes' CrashLoopBackOff
# floor), `backoff_cap: :timer.minutes(5)`, and `stable_window: :timer.minutes(10)`;
# we lower all three here for quick responsiveness — a 500ms first restart,
# capped at 30s, with the counter resetting after a 30s stable run.
config :tank, :reconciler,
  backoff_base: 500,
  backoff_cap: :timer.seconds(30),
  stable_window: :timer.seconds(30)

# --- The web face (lib/tank_web) --------------------------------------------
# Compile-time endpoint/asset config. Whether the endpoint actually *starts*
# is a runtime decision (`config :tank, :web, enabled: true` — see dev.exs and
# runtime.exs); with it absent Tank boots headless exactly as before.

config :tank, TankWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: TankWeb.ErrorHTML], layout: false],
  pubsub_server: Tank.PubSub,
  live_view: [signing_salt: "gJ8kQ2xT"]

config :phoenix, :json_library, Jason

# esbuild: app.js bundled as ESM (loaded with type="module") so import.meta
# resolves — required by Gooey's terminal hooks. NODE_PATH lists
# assets/node_modules first so packages used by hooks (@wterm/dom) resolve
# even when the importing hook lives in the Gooey dep.
esbuild_node_path = [
  Path.expand("../assets/node_modules", __DIR__),
  Path.expand("../deps", __DIR__),
  Mix.Project.build_path()
]

config :esbuild,
  version: "0.25.4",
  tank: [
    args:
      ~w(js/app.js --bundle --format=esm --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => esbuild_node_path}
  ]

config :tailwind,
  version: "4.1.12",
  tank: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Environment-specific config (dev watchers, test store settings, …).
import_config "#{config_env()}.exs"
