import Config

# Operational config: where Tank keeps its data. A consumer sets
# TANK_DATA_DIR or overrides `:tank, :data_dir` directly; standalone Tank
# defaults to a per-user cache directory.
data_dir =
  System.get_env("TANK_DATA_DIR") ||
    to_string(:filename.basedir(:user_cache, ~c"tank"))

config :tank, data_dir: data_dir

# Where pulled OCI images are cached (content-addressed: blobs/, rootfs/, refs/).
# A plain path, independent of the data dir, that survives restarts. Override
# with TANK_IMAGE_CACHE or this key; defaults to the XDG user cache (~/.cache/tank).
config :tank,
  image_cache:
    System.get_env("TANK_IMAGE_CACHE") || to_string(:filename.basedir(:user_cache, ~c"tank"))

# The default store lives under data_dir. A consumer running its own Khepri
# (BYO) instead sets `config :tank, :store, store_id: :their_store` with no
# `:data_dir`, so Tank attaches to it rather than booting one.
config :tank, :store, data_dir: Path.join(data_dir, "khepri")

# Desired-state seed: pods written *create-if-absent* on a fresh store, so the
# boot seed never clobbers state changed at runtime. Empty by default; add pods
# here (or declare them at runtime with `Tank.apply/1`).
config :tank, pods: []

# --- The web face ------------------------------------------------------------
# Opt-in: TANK_WEB=1 (or `config :tank, :web, enabled: true` from the consumer /
# dev.exs) starts the admin UI. Absent → headless, exactly as before.
if System.get_env("TANK_WEB") in ~w(1 true) do
  config :tank, :web, enabled: true
end

web_enabled? =
  Application.get_env(:tank, :web, [])[:enabled] || System.get_env("TANK_WEB") in ~w(1 true)

# Dev is fully configured by dev.exs (mix phx.server serves); this block is
# the production/release path.
if web_enabled? && config_env() == :prod do
  config :tank, TankWeb.Endpoint,
    server: true,
    http: [
      ip: {127, 0, 0, 1},
      port: String.to_integer(System.get_env("TANK_WEB_PORT") || "4400")
    ],
    # No auth yet (localhost-bound). The per-boot random secret means LiveView
    # sessions don't survive a restart — a reconnect, harmless without auth.
    # Must become persistent (TANK_SECRET_KEY_BASE) at the login milestone.
    secret_key_base:
      System.get_env("TANK_SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))
end
