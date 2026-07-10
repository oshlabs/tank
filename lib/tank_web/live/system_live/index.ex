defmodule TankWeb.SystemLive.Index do
  @moduledoc false
  use TankWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "System", facts: facts())}
  end

  defp facts do
    %{
      data_dir: Application.get_env(:tank, :data_dir),
      image_cache: Application.get_env(:tank, :image_cache),
      net_enabled: Tank.Net.enabled?(),
      versions:
        for app <- [:tank, :linx, :stevedore, :starfish, :gooey, :phoenix] do
          {app, Application.spec(app, :vsn) |> to_string()}
        end,
      otp: :erlang.system_info(:otp_release) |> to_string(),
      elixir: System.version()
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} suite={@suite}>
      <:page_title>System</:page_title>

      <.description_list>
        <:item label="Data dir">{@facts.data_dir}</:item>
        <:item label="Image cache">{@facts.image_cache}</:item>
        <:item label="Network services">
          {if @facts.net_enabled, do: "enabled", else: "disabled"}
        </:item>
        <:item label="Elixir / OTP">{@facts.elixir} / OTP {@facts.otp}</:item>
        <:item :for={{app, vsn} <- @facts.versions} label={to_string(app)}>{vsn}</:item>
      </.description_list>
    </Layouts.app>
    """
  end
end
