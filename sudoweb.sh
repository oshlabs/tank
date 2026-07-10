#!/bin/sh
# Run the tank_web dev server as root — real container actuation (namespaces,
# cgroups, netlink) needs it. Non-root `mix phx.server` also works for pure
# UI work; pods then fail to converge, which the UI shows honestly.
#
# The asdf *shim* (`exec asdf exec mix`) dies silently under sudo, so resolve
# the real toolchain binaries first and hand sudo an explicit PATH + MIX_HOME
# (hex/rebar live inside the asdf elixir install, not ~/.mix).
#
# Note: the dev code reloader and asset watchers write _build/ and
# priv/static/ as root; run `sudo chown -R $USER _build priv` afterwards if
# a later non-root compile complains.
cd "$(dirname "$0")" || exit 1

MIX_BIN="$(asdf which mix 2>/dev/null || command -v mix)" || exit 1
ERL_BIN="$(asdf which erl 2>/dev/null || command -v erl)" || exit 1
ELIXIR_BIN_DIR="$(dirname "$MIX_BIN")"
ERL_BIN_DIR="$(dirname "$ERL_BIN")"

exec sudo env \
  "PATH=$ELIXIR_BIN_DIR:$ERL_BIN_DIR:/usr/bin:/bin" \
  "HOME=$HOME" \
  "MIX_HOME=${MIX_HOME:-$(dirname "$ELIXIR_BIN_DIR")/.mix}" \
  "$MIX_BIN" phx.server
