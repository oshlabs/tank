# Tank's tests spawn containers into fresh network namespaces, which needs
# root. They are tagged :integration and excluded by default; run them with
# `sudo mix test --include integration` (see ./sudotest.sh).
#
# :network tests reach a real image registry (Docker Hub); they are also
# excluded by default — run with `mix test --include network`.
ExUnit.start(exclude: [:integration, :network])
