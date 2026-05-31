defmodule Tank.OCITest do
  use ExUnit.Case, async: true

  alias Tank.{Container, OCI}

  defp container(attrs \\ %{}) do
    Container.new!(Map.merge(%{name: "c", image: "img"}, attrs))
  end

  defp image(cfg), do: %{"config" => cfg}

  describe "argv" do
    test "image Entrypoint ++ Cmd when the spec overrides neither" do
      cfg = image(%{"Entrypoint" => ["/bin/app"], "Cmd" => ["--serve"]})
      assert {:ok, %{argv: ["/bin/app", "--serve"]}} = OCI.run_params(container(), cfg)
    end

    test "spec command overrides Entrypoint and resets the image Cmd" do
      cfg = image(%{"Entrypoint" => ["/bin/app"], "Cmd" => ["--serve"]})
      c = container(%{command: ["/bin/sleep", "60"]})
      assert {:ok, %{argv: ["/bin/sleep", "60"]}} = OCI.run_params(c, cfg)
    end

    test "spec command ++ args is a full override" do
      cfg = image(%{"Entrypoint" => ["/bin/app"], "Cmd" => ["--serve"]})
      c = container(%{command: ["/bin/sh"], args: ["-c", "echo hi"]})
      assert {:ok, %{argv: ["/bin/sh", "-c", "echo hi"]}} = OCI.run_params(c, cfg)
    end

    test "spec args override Cmd" do
      cfg = image(%{"Entrypoint" => ["/bin/app"], "Cmd" => ["--serve"]})
      c = container(%{args: ["--debug"]})
      assert {:ok, %{argv: ["/bin/app", "--debug"]}} = OCI.run_params(c, cfg)
    end

    test "no command in spec or image is an error" do
      assert {:error, :no_command} = OCI.run_params(container(), image(%{}))
    end
  end

  describe "env" do
    test "image Env with the spec env merged over it (spec wins)" do
      cfg = image(%{"Cmd" => ["/x"], "Env" => ["PATH=/usr/bin", "TZ=UTC"]})
      c = container(%{env: %{"TZ" => "Europe/Amsterdam", "EXTRA" => "1"}})
      {:ok, %{env: env}} = OCI.run_params(c, cfg)

      assert "PATH=/usr/bin" in env
      assert "TZ=Europe/Amsterdam" in env
      assert "EXTRA=1" in env
      refute "TZ=UTC" in env
    end
  end

  describe "cwd" do
    test "spec working_dir wins, then image WorkingDir, then /" do
      base = %{"Cmd" => ["/x"]}

      assert {:ok, %{cwd: "/app"}} =
               OCI.run_params(container(%{working_dir: "/app"}), image(base))

      assert {:ok, %{cwd: "/srv"}} =
               OCI.run_params(container(), image(Map.put(base, "WorkingDir", "/srv")))

      assert {:ok, %{cwd: "/"}} = OCI.run_params(container(), image(base))
    end
  end

  test "tolerates a missing or non-map image config" do
    c = container(%{command: ["/bin/sh"]})
    assert {:ok, %{argv: ["/bin/sh"], cwd: "/", env: []}} = OCI.run_params(c, %{})
    assert {:ok, %{argv: ["/bin/sh"]}} = OCI.run_params(c, %{"config" => nil})
  end
end
