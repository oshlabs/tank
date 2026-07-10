defmodule TankWeb.WebE2ETest do
  # The whole face against reality: a real pod behind the real screens —
  # live status on the list, logs seeded into the viewer, a terminal exec
  # round-trip, restart, delete. Needs root (real containers).
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag capture_log: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  use TankWeb, :verified_routes

  @endpoint TankWeb.Endpoint

  alias Tank.Reconciler

  setup_all do
    deck = Tank.TestImages.deckhand!()
    dir = Path.join(System.tmp_dir!(), "tank-web-e2e-#{System.unique_integer([:positive])}")

    # The screens read logs via the configured :data_dir; point it at the
    # same place the runtimes write (production wires both from one config).
    previous = Application.get_env(:tank, :data_dir)
    Application.put_env(:tank, :data_dir, dir)
    on_exit(fn -> Application.put_env(:tank, :data_dir, previous) end)

    start_supervised!({Tank.Store, data_dir: dir})
    start_supervised!({Phoenix.PubSub, name: Tank.PubSub})
    start_supervised!(TankWeb.Endpoint)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, deck: deck, dir: dir}
  end

  setup %{deck: deck} do
    for pod <- Tank.list(), do: Tank.delete(pod.name)

    start_supervised!(
      {Reconciler, runtime: Tank.Runtime, runtime_opts: [image: deck.image_opts], interval: 500}
    )

    start_supervised!({Tank.Stats, interval: 200})

    {:ok, conn: build_conn()}
  end

  test "a pod's whole life through the screens", %{conn: conn, deck: deck} do
    # Declare through the domain (the modal is covered non-root); the
    # reconciler picks it up on its own cadence, as in production.
    :ok =
      Tank.apply(%{
        name: "webe2e",
        network: :none,
        restart: :always,
        containers: [%{name: "app", image: deck.ref}]
      })

    # --- the list goes live ------------------------------------------------
    {:ok, index, _html} = live(conn, ~p"/pods")
    assert render_eventually(index, "running", 30_000)

    # --- the detail header: running badge, stats flowing --------------------
    {:ok, view, _html} = live(conn, ~p"/pods/webe2e")
    assert render_eventually(view, "running", 15_000)

    # The stats sampler feeds the tiles (memory shows up as MiB/KiB).
    assert render_eventually(view, "iB", 10_000)

    # --- logs: the viewer replays the captured ring on hook-ready ----------
    view |> element("nav a", "Logs") |> render_click()
    view |> element("#logs-webe2e") |> render_hook("lv_ready", %{})
    assert_push_event(view, "lv_seed", %{lines: lines}, 10_000)
    assert Enum.any?(lines, &(&1.text =~ "deckhand" or &1.text =~ "serving"))

    # --- terminal: exec an applet, watch its bytes come back ---------------
    view |> element("nav a", "Terminal") |> render_click()

    view
    |> form("form[phx-submit=exec]", %{cmd: "/bin/env"})
    |> render_submit()

    assert_push_event(view, "term_output", %{data: data}, 15_000)
    output = data <> collect_term_output(view)
    assert output =~ "PATH="
    # The applet ran to completion: the session-ended banner followed.
    assert output =~ "session ended"

    # A (re)mounting terminal hook gets the scrollback replayed — the fix for
    # output racing the hook's init, and for tab-switch remounts.
    view |> element("#term-webe2e") |> render_hook("term_ready", %{})
    assert_push_event(view, "term_output", %{data: replay}, 5_000)
    replay = replay <> collect_term_output(view)
    assert replay =~ "PATH="
    assert replay =~ "session ended"

    # --- restart ------------------------------------------------------------
    view |> element("button", "Restart") |> render_click()
    assert render(view) =~ "restarting webe2e"

    # --- delete navigates away ----------------------------------------------
    view |> element("button", "Delete") |> render_click()
    assert_redirect(view, "/pods")
    assert {:error, :not_found} = Tank.get("webe2e")
  end

  # Drain queued term_output push_events into one string.
  defp collect_term_output(view, acc \\ "") do
    assert_push_event(view, "term_output", %{data: data}, 5_000)
    collect_term_output(view, acc <> data)
  rescue
    ExUnit.AssertionError -> acc
  end

  defp render_eventually(view, needle, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_render_eventually(view, needle, deadline)
  end

  defp do_render_eventually(view, needle, deadline) do
    cond do
      render(view) =~ needle -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(100) && do_render_eventually(view, needle, deadline)
    end
  end
end
