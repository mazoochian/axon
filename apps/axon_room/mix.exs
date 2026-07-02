defmodule AxonRoom.MixProject do
  use Mix.Project

  def project do
    [
      app: :axon_room,
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
      mod: {AxonRoom.Application, []}
    ]
  end

  defp deps do
    [
      {:axon_core, in_umbrella: true},
      {:axon_push, in_umbrella: true},
      {:horde, "~> 0.9"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.2"}
    ]
  end
end
