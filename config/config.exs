import Config

# Compile-time operational defaults. *Desired* state (which pods) is seeded at
# runtime — see config/runtime.exs.

# Whether the application supervisor starts (and owns) a Khepri store. Consumers
# that run their own store, and the test suite, set this to false.
config :tank, start_store?: true

# The host-config adapter (uplink + DNS facts). The default reads them from
# config; a consumer (e.g. TankOS) swaps in its own. See `Tank.Host`.
config :tank, host: Tank.Host.Static

# Reconciler restart backoff: the first restart waits `backoff_base`, doubling
# on repeated rapid failures up to `backoff_cap`. The in-code defaults are
# `backoff_base: :timer.seconds(10)` (matching Kubernetes' CrashLoopBackOff
# floor) and `backoff_cap: :timer.minutes(5)`; we lower both here for quick
# responsiveness — a 500ms first restart, capped at 30s — so an interactive pod
# you just exited comes right back rather than after ~10s.
config :tank, :reconciler,
  backoff_base: 500,
  backoff_cap: :timer.seconds(30)

if config_env() == :test do
  import_config "test.exs"
end
