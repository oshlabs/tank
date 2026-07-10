defmodule TankWeb.PodLiveTest do
  # The screens over a real store (tmp dir) with no reconciler: everything
  # reads honestly as :pending, and desired-state writes round-trip. No root.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  use TankWeb, :verified_routes

  @endpoint TankWeb.Endpoint

  setup_all do
    dir = Path.join(System.tmp_dir!(), "tank-web-test-#{System.unique_integer([:positive])}")
    start_supervised!({Tank.Store, data_dir: dir})
    start_supervised!({Phoenix.PubSub, name: Tank.PubSub})
    start_supervised!(TankWeb.Endpoint)
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    for pod <- Tank.list(), do: Tank.delete(pod.name)
    {:ok, conn: build_conn()}
  end

  test "the pod list starts empty and offers the apply action", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/pods")

    assert html =~ "No pods declared"
    assert html =~ "Apply pod"
  end

  test "applying a literal spec declares the pod and lists it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pods")

    view |> element("#apply-pod") |> render_click()

    html =
      view
      |> form("#apply-modal form",
        spec: ~S(%{name: "web", containers: [%{name: "app", image: "nginx:1.27"}]})
      )
      |> render_submit()

    assert html =~ "web"
    assert {:ok, %Tank.Pod{name: "web"}} = Tank.get("web")
    # No reconciler running → honestly pending.
    assert html =~ "pending"
  end

  test "a non-literal spec is refused", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pods")

    view |> element("#apply-pod") |> render_click()

    html =
      view
      |> form("#apply-modal form", spec: ~S[%{name: File.read!("/etc/passwd")}])
      |> render_submit()

    assert html =~ "literal map"
    assert Tank.list() == []
  end

  test "a pod event from elsewhere refreshes the list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pods")
    assert render(view) =~ "No pods declared"

    # Another writer (iex, another tab) applies a pod — the :pods event
    # triggers the coalesced re-read.
    :ok = Tank.apply(%{name: "other", containers: [%{name: "c", image: "alpine"}]})

    assert render_eventually(view, "other")
  end

  test "the detail page renders, tabs patch, and delete navigates away", %{conn: conn} do
    :ok = Tank.apply(%{name: "web", containers: [%{name: "app", image: "nginx:1.27"}]})

    {:ok, view, html} = live(conn, ~p"/pods/web")
    assert html =~ "web"
    assert html =~ "pending"

    # Tabs are routes: patch to spec and see the rendered pod struct.
    html = view |> element("nav a", "Spec") |> render_click()
    assert html =~ "Tank.Pod"
    assert_patch(view, ~p"/pods/web/spec")

    # Terminal tab renders the chooser with exec disabled (pod not running).
    html = view |> element("nav a", "Terminal") |> render_click()
    assert html =~ "New shell"
    assert html =~ "The pod must be running"

    # Delete navigates back to the list.
    view |> element("button", "Delete") |> render_click()
    assert_redirect(view, "/pods")
    assert {:error, :not_found} = Tank.get("web")
  end

  test "an unknown pod redirects to the list with a flash", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/pods"}}} = live(conn, ~p"/pods/nope")
  end

  test "networks and system render without network services", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/networks")
    assert html =~ "No pools declared"

    {:ok, _view, html} = live(conn, ~p"/system")
    assert html =~ "Data dir"
  end

  # Re-render until `needle` appears (event delivery is async), max ~1s.
  defp render_eventually(view, needle, tries \\ 50)
  defp render_eventually(_view, _needle, 0), do: false

  defp render_eventually(view, needle, tries) do
    if render(view) =~ needle do
      true
    else
      Process.sleep(20)
      render_eventually(view, needle, tries - 1)
    end
  end
end
