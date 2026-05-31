# Tank's tests spawn containers into fresh network namespaces, which needs
# root. They are tagged :integration and excluded by default; run them with
# `sudo mix test --include integration` (see ./sudotest.sh).
ExUnit.start(exclude: [:integration])
