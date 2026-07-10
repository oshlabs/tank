defmodule TankWeb.ErrorHTML do
  @moduledoc false
  use TankWeb, :html

  # Renders "404 Not Found", "500 Internal Server Error", etc.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
