import Config

# Tests boot their own Khepri store in a tmp dir (see Tank.StoreTest), so the
# application supervisor must not start a competing one.
config :tank, start_store?: false

# Quiet Ra/Khepri leader-election chatter (debug/info/notice) in test output.
config :logger, level: :warning
