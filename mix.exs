defmodule Tank.MixProject do
  use Mix.Project

  # Tank is a proof-of-concept *consumer* of Linx, not part of the Linx
  # package. It lives in this nested app — with a path dependency on the
  # parent — so it can only reach Linx's public API, never its internals.
  # Lifting it into its own repo later is `git mv tank ../tank` plus flipping
  # the dep below to `{:linx, "~> x.y"}`.

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
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:linx, path: ".."},
      # HTTP client for the OCI registry client (Tank.Image.Registry).
      {:req, "~> 0.5"},
      # Tree-structured, Raft-replicated desired-state store (Tank.Store).
      {:khepri, "~> 0.18.0"}
    ]
  end
end
