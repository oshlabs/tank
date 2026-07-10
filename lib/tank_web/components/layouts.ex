defmodule TankWeb.Layouts do
  @moduledoc """
  Root skeleton (`layouts/root.html.heex`) plus the app layout: every screen
  renders inside Gooey's `app_shell`, fed by the `@suite` config that
  `TankWeb.Nav` assembles.
  """

  use TankWeb, :html

  embed_templates("layouts/*")

  attr(:flash, :map, required: true)
  attr(:suite, Gooey.SuiteConfig, required: true)

  slot(:page_title)
  slot(:actions)
  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <.app_shell config={@suite} flash={@flash}>
      <:page_title>{render_slot(@page_title)}</:page_title>
      <:actions>{render_slot(@actions)}</:actions>
      {render_slot(@inner_block)}
    </.app_shell>
    """
  end
end
