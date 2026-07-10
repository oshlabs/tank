# Tank's tests spawn containers into fresh network namespaces, which needs
# root. They are tagged :integration and excluded by default; run them with
# `sudo mix test --include integration` (see ./sudotest.sh).
#
# No test reaches Docker Hub. Registry mechanics run against a hermetic local
# registry (Stevedore.Testing); the root e2e suites use real distro images
# from a persistent cache, seeded once from ECR's public mirror when cold
# (Tank.TestImages) — a warm run touches no network at all.
ExUnit.start(exclude: [:integration])
