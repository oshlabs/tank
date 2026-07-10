defmodule TankWeb.Status do
  @moduledoc """
  Presentation helpers over the domain's merged view (`Tank.status/0`):
  badge colors, address chips, age/exit labels. Pure functions — the screens
  own subscriptions and refresh.
  """

  @doc "Every declared pod's merged status row (see `Tank.status/0`)."
  @spec rows() :: [Tank.pod_status()]
  def rows, do: Tank.status()

  @doc "Gooey badge variant for a pod status."
  @spec badge_color(atom()) :: String.t()
  def badge_color(:running), do: "success"
  def badge_color(:starting), do: "info"
  def badge_color(:backing_off), do: "warning"
  def badge_color(:terminal), do: "error"
  def badge_color(_), do: "neutral"

  @doc "Counts per status, for the stat tiles."
  @spec counts([Tank.pod_status()]) :: %{atom() => non_neg_integer()}
  def counts(rows), do: Enum.frequencies_by(rows, & &1.status)

  @doc """
  A pod's resolved addresses, one entry per NIC with one: `%{nic:, ip:}`.
  IPAM-intent NICs are resolved through the live allocation; static NICs read
  straight from the spec. Empty for `:host`/`:none` pods or when nothing is
  allocated (yet).
  """
  @spec addresses(Tank.Pod.t()) :: [%{nic: String.t(), ip: String.t()}]
  def addresses(%Tank.Pod{name: name, network: %{nics: nics}}) when is_list(nics) do
    for nic <- nics, ip = nic_ip(name, nic), do: %{nic: nic.name, ip: ip}
  end

  def addresses(_pod), do: []

  defp nic_ip(pod_name, %{name: nic_name, ip: {:ipam, _subnet}}) do
    case Starfish.IPAM.lookup({:tank_pod, pod_name, nic_name}) do
      [%{ip: ip} | _] -> Starfish.IP.to_string(ip)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp nic_ip(_pod_name, %{ip: {addr, _prefix}}) when is_binary(addr), do: addr
  defp nic_ip(_pod_name, _nic), do: nil

  @doc "The pod's DNS name when the DNS service is configured, else nil."
  @spec dns_name(String.t()) :: String.t() | nil
  def dns_name(pod_name) do
    net = Application.get_env(:tank, :net) || []

    case Keyword.get(net, :dns, []) do
      false -> nil
      dns_opts -> "#{pod_name}.#{Keyword.get(dns_opts, :origin, "tank.internal")}"
    end
  end

  @doc ~S(A compact "how long ago" label — "3m", "2h", "5d".)
  @spec age(DateTime.t() | nil) :: String.t()
  def age(nil), do: "—"

  def age(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 0 -> "—"
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  @doc "A human label for a pod's last exit."
  @spec exit_label(Tank.Events.last_exit() | nil) :: String.t() | nil
  def exit_label(nil), do: nil
  def exit_label({:exited, 0}), do: "exited cleanly"
  def exit_label({:exited, code}), do: "exited #{code}"
  def exit_label({:signaled, signum}), do: "killed by signal #{signum}"
  def exit_label({:error, reason}), do: "failed: #{inspect(reason)}"

  @doc "Bytes as a compact human string."
  @spec bytes(number() | nil) :: String.t()
  def bytes(nil), do: "—"
  def bytes(n) when n < 1024, do: "#{round(n)} B"
  def bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KiB"
  def bytes(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / (1024 * 1024), 1)} MiB"
  def bytes(n), do: "#{Float.round(n / (1024 * 1024 * 1024), 2)} GiB"

  @doc "A rate as B/s / KiB/s / MiB/s."
  @spec rate(number() | nil) :: String.t()
  def rate(nil), do: "—"
  def rate(n), do: bytes(n) <> "/s"

  @doc "A percentage with one decimal."
  @spec percent(number() | nil) :: String.t()
  def percent(nil), do: "—"
  def percent(n), do: "#{Float.round(n * 1.0, 1)}%"
end
