defmodule Tank.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/oshlabs/tank"

  # Tank is a *consumer* of Linx, not part of the Linx package. It depends on
  # Linx as a published hex package, so it can only reach Linx's public API,
  # never its internals.

  def project do
    [
      app: :tank,
      version: @version,
      elixir: "~> 1.15",
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
      links: %{"GitHub" => @source_url},
      # Ship only the library sources. The dev-time config/, the docs/ extras
      # (rendered to hexdocs separately), and the sudo helper scripts are not
      # part of the package; Tank reads its own config with in-code defaults,
      # so consumers supply config, never these files.
      files: ~w(lib mix.exs README.md LICENSE),
      maintainers: ["Leon de Rooij"]
    ]
  end

  defp deps do
    [
      {:linx, "~> 0.1"},
      # HTTP client for the OCI registry client (Tank.Image.Registry).
      {:req, "~> 0.5"},
      # Tree-structured, Raft-replicated desired-state store (Tank.Store).
      {:khepri, "~> 0.18.0"},
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
        "docs/EXAMPLES.md": [title: "Tank by example"],
        LICENSE: [title: "License"]
      ]
    ]
  end
end
