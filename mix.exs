defmodule Tank.MixProject do
  use Mix.Project

  # Tank is a *consumer* of Linx, not part of the Linx package. It depends on
  # Linx via a path dependency on a sibling checkout (`../linx`) so it can only
  # reach Linx's public API, never its internals. When Linx is published, this
  # flips to a hex dependency `{:linx, "~> x.y"}`.

  def project do
    [
      app: :tank,
      version: "0.0.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Tank.Application, []}
    ]
  end

  defp deps do
    [
      {:linx, path: "../linx"},
      # HTTP client for the OCI registry client (Tank.Image.Registry).
      {:req, "~> 0.5"},
      # Tree-structured, Raft-replicated desired-state store (Tank.Store).
      {:khepri, "~> 0.18.0"}
    ]
  end
end
