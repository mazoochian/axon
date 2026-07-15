defmodule AxonWeb.Telemetry do
  @moduledoc """
  Wires the `:telemetry`/`:telemetry_metrics`/`:telemetry_poller` deps
  (declared in `mix.exs` since day one but never attached to anything) to
  real Phoenix, Ecto, VM, and process-mailbox-depth measurements, and
  mounts them on LiveDashboard. A future OTel/Prometheus exporter (not
  wired yet, see ROADMAP.md) would attach to the same `metrics/0` list.

  VM metrics (`vm.memory`, `vm.total_run_queue_lengths`) need no explicit
  measurement here — `:telemetry_poller`'s own application-level default
  poller emits those automatically once the dependency is started.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: :timer.seconds(10)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix — CS API endpoint request duration
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      counter("phoenix.endpoint.stop.duration"),

      # Ecto — apps/axon_core/lib/axon_core/repo.ex has no explicit
      # :telemetry_prefix, so Ecto derives the default [:axon_core, :repo].
      summary("axon_core.repo.query.total_time", unit: {:native, :millisecond}),
      summary("axon_core.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("axon_core.repo.query.query_time", unit: {:native, :millisecond}),
      summary("axon_core.repo.query.idle_time", unit: {:native, :millisecond}),

      # VM
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Mailbox depth of the app's key single-process bottlenecks — cheap
      # early warning if one of them starts falling behind under load.
      last_value("axon.mailbox.axon_sync_manager.length"),
      last_value("axon.mailbox.axon_web_rate_limiter.length"),
      last_value("axon.mailbox.axon_federation_outbound_queue.length")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :dispatch_mailbox_depths, []}
    ]
  end

  @doc false
  def dispatch_mailbox_depths do
    for {metric_name, process_name} <- [
          {:axon_sync_manager, AxonSync.Manager},
          {:axon_web_rate_limiter, AxonWeb.RateLimiter},
          {:axon_federation_outbound_queue, AxonFederation.OutboundQueue}
        ] do
      length =
        case process_name
             |> Process.whereis()
             |> then(&(&1 && Process.info(&1, :message_queue_len))) do
          {:message_queue_len, len} -> len
          _ -> 0
        end

      :telemetry.execute([:axon, :mailbox, metric_name], %{length: length}, %{})
    end
  end
end
