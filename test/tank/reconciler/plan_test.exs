defmodule Tank.Reconciler.PlanTest do
  use ExUnit.Case, async: true

  alias Tank.Pod
  alias Tank.Reconciler.Plan

  defp pod(name, attrs \\ %{}) do
    Pod.new!(Map.merge(%{name: name, containers: [%{name: "c", image: "alpine"}]}, attrs))
  end

  defp running(pods), do: Map.new(pods, &{&1.name, &1})

  test "nothing desired, nothing running" do
    assert %{start: [], stop: [], restart: []} = Plan.diff([], %{})
  end

  test "desired and not running -> start" do
    web = pod("web")
    assert %{start: [^web], stop: [], restart: []} = Plan.diff([web], %{})
  end

  test "running and not desired -> stop (by name)" do
    assert %{start: [], stop: ["web"], restart: []} = Plan.diff([], running([pod("web")]))
  end

  test "unchanged -> no action" do
    web = pod("web")
    assert %{start: [], stop: [], restart: []} = Plan.diff([web], running([web]))
  end

  test "desired-but-changed -> restart with the new spec" do
    v1 = pod("web", %{restart: :always})
    v2 = pod("web", %{restart: :never})
    assert %{start: [], stop: [], restart: [^v2]} = Plan.diff([v2], running([v1]))
  end

  test "a mixed pass" do
    keep = pod("keep")
    changed_old = pod("changed", %{restart: :always})
    changed_new = pod("changed", %{restart: :never})
    add = pod("add")
    gone = pod("gone")

    plan = Plan.diff([keep, changed_new, add], running([keep, changed_old, gone]))

    assert plan.start == [add]
    assert plan.stop == ["gone"]
    assert plan.restart == [changed_new]
  end
end
