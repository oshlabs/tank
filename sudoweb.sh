#!/bin/sh
# Run the tank_web dev server as root — real container actuation (namespaces,
# cgroups, netlink) needs it. Non-root `mix phx.server` also works for pure
# UI work; pods then fail to converge, which the UI shows honestly.
#
# Mirrors sudorun.sh/sudotest.sh: preserve the caller's toolchain PATH so the
# asdf-installed mix/erl survive sudo.
cd "$(dirname "$0")" || exit 1
exec sudo --preserve-env=PATH,HOME,ASDF_DIR,ASDF_DATA_DIR,MIX_HOME \
  env "PATH=$PATH" "$(command -v mix)" phx.server
