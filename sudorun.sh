#!/bin/sh
# Start an `iex -S mix` session as root — needed to drive Tank by hand, since
# spawning containers (namespaces, mounts, netlink) is privileged. Mirrors the
# parent repo's script; preserves the asdf-managed Elixir toolchain across sudo.
sudo --preserve-env=PATH,HOME,ASDF_DIR env "PATH=$PATH" "$(which iex)" -S mix
