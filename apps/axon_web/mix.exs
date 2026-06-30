defmodule AxonWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :axon_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AxonWeb.Application, []}
    ]
  end

  defp deps do
    [
      {:axon_crypto, in_umbrella: true},
      {:axon_core, in_umbrella: true},
      {:axon_room, in_umbrella: true},
      {:axon_federation, in_umbrella: true},
      {:axon_sync, in_umbrella: true},
      {:axon_media, in_umbrella: true},
      {:axon_push, in_umbrella: true},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.4"},
      {:finch, "~> 0.19"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:telemetry, "~> 1.2"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:mox, "~> 1.1", only: :test}
    ]
  end
end
