defmodule Tank.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/oshlabs/tank"

  # Tank is a *consumer* of Linx, not part of the Linx package. It depends on
  # Linx as a published hex package, so it can only reach Linx's public API,
  # never its internals.

  def project do
    [
      app: :tank,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      name: "Tank",
      description:
        "A declarative container orchestrator for Linux, built on the public Linx " <>
          "API: declare pods of namespaced workloads as data, and a reconcile loop " <>
          "converges the machine onto them — host-reconciled macvlan networking, " <>
          "cgroup limits, and a Khepri-backed desired-state store.",
      source_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Tank.Application, []}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      # Ship only the library sources. The dev-time config/, the docs/ extras
      # (rendered to hexdocs separately), and the sudo helper scripts are not
      # part of the package; Tank reads its own config with in-code defaults,
      # so consumers supply config, never these files.
      files: ~w(lib mix.exs README.md LICENSE),
      maintainers: ["Leon de Rooij"]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Sibling checkout — Tank needs linx's unreleased enter/2 fix (ceaeb2a,
      # after v0.2.0): released enter joined only the namespaces preceding
      # :mount — once setns(mnt) ran, /proc/<host_pid> path lookups resolved
      # in the target's /proc and every later type (uts/ipc/net/pid) fell to
      # the all-ns ENOENT skip, so Tank.exec landed in the pod's rootfs but
      # the HOST's netns/pidns. The two-phase join (pin the /proc dirfd, open
      # all ns fds before the first setns) fixes it; caught by the deckhand
      # exec e2e (the second instance bound the "taken" port). Release linx
      # 0.2.1+ and return this to a hex dep.
      {:linx, path: "../linx"},
      # OCI toolkit — all registry fetching goes through Stevedore (Tank.Image.Registry
      # is a thin shim over it). 0.2 adds the token cache the shim threads per pull. Its
      # docker:// client uses :req, declared below.
      # Sibling checkout while Stevedore.Testing (the suite's hermetic local
      # registry) is unreleased — back to `"~> 0.3"` on hex when it ships.
      {:stevedore, path: "../stevedore"},
      # HTTP client: Tank.Image.Registry's shim and Stevedore's docker:// client both use it.
      {:req, "~> 0.5"},
      # Tree-structured, Raft-replicated desired-state store (Tank.Store).
      {:khepri, "~> 0.18.0"},
      # Network services (IPAM, and later DNS/DHCP/RA) embedded per the plan:
      # pod NICs draw addresses from Starfish IPAM (Tank.Ipam), stored in a
      # [:starfish] subtree of Tank's own Khepri store. Pre-Hex sibling
      # checkout; becomes a hex dep when Starfish is renamed + published.
      {:starfish, path: "../starfish"},
      # Test-only: activate Stevedore's optional registry server (Plug over
      # Bandit) so the suite pulls from a local, hermetic registry instead of
      # Docker Hub — see test/support/local_registry.ex.
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.5", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      # Generated HTML lands under _build/, alongside other build artefacts.
      output: "_build/docs",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/EXAMPLES.md": [title: "Tank by example"],
        LICENSE: [title: "License"]
      ]
    ]
  end
end
