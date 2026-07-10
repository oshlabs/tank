import Config

# Tests boot their own Khepri store in a tmp dir (see Tank.StoreTest), so the
# application supervisor must not start a competing one.
config :tank, start_store?: false

# Quiet Ra/Khepri leader-election chatter (debug/info/notice) in test output.
config :logger, level: :warning

# LiveView tests drive views through the endpoint module without a listening
# server; the endpoint itself never starts unless a test asks for it.
config :tank, TankWeb.Endpoint,
  server: false,
  secret_key_base: String.duplicate("tanktest", 8)
