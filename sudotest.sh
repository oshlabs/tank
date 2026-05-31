#!/bin/sh
# Run Tank's tests as root, including the :integration tests (which spawn
# containers into fresh network namespaces). Mirrors the parent repo's script.
# Extra arguments are passed through to `mix test`.
sudo --preserve-env=PATH,HOME,ASDF_DIR env "PATH=$PATH" "$(which mix)" test --include integration "$@"
