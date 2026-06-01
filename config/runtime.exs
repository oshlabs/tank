import Config

# Operational config: where Tank keeps its data. A consumer (e.g. TankOS) sets
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
  image_cache: System.get_env("TANK_IMAGE_CACHE") || to_string(:filename.basedir(:user_cache, ~c"tank"))

# The default store lives under data_dir. A consumer running its own Khepri
# (BYO) instead sets `config :tank, :store, store_id: :their_store` with no
# `:data_dir`, so Tank attaches to it rather than booting one.
config :tank, :store, data_dir: Path.join(data_dir, "khepri")

# Desired-state seed: pods written *create-if-absent* on a fresh store, so the
# boot seed never clobbers state changed at runtime. Empty by default; add pods
# here (or declare them at runtime with `Tank.apply/1`).
config :tank, pods: []
