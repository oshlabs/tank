#!/bin/sh
# Run the tank_web dev server as root — real container actuation (namespaces,
# cgroups, netlink) needs it. Non-root `mix phx.server` also works for pure
# UI work; pods then fail to converge, which the UI shows honestly.
#
# The asdf *shim* (`exec asdf exec mix`) dies silently under sudo, so resolve
# the real toolchain binaries first and hand sudo an explicit PATH + MIX_HOME
# (hex/rebar live inside the asdf elixir install, not ~/.mix).
#
# Note: the asset watchers still write priv/static/assets as root; run
# `sudo chown -R $USER priv` if a later non-root assets.build complains.
cd "$(dirname "$0")" || exit 1

MIX_BIN="$(asdf which mix 2>/dev/null || command -v mix)" || exit 1
ERL_BIN="$(asdf which erl 2>/dev/null || command -v erl)" || exit 1
ELIXIR_BIN_DIR="$(dirname "$MIX_BIN")"
ERL_BIN_DIR="$(dirname "$ERL_BIN")"

# Root runs build into their own tree (_build-sudo): alternating root and
# user runs in one _build forces a full recompile every time (and the chown
# dance afterwards forces the next one). Separate trees never collide.
exec sudo env \
  "PATH=$ELIXIR_BIN_DIR:$ERL_BIN_DIR:/usr/bin:/bin" \
  "HOME=$HOME" \
  "MIX_HOME=${MIX_HOME:-$(dirname "$ELIXIR_BIN_DIR")/.mix}" \
  "MIX_BUILD_ROOT=$PWD/_build-sudo" \
  "$MIX_BIN" phx.server
