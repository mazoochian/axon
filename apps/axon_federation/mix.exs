defmodule AxonFederation.MixProject do
  use Mix.Project

  def project do
    [
      app: :axon_federation,
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
      mod: {AxonFederation.Application, []}
    ]
  end

  defp deps do
    [
      {:axon_core, in_umbrella: true},
      {:axon_room, in_umbrella: true},
      {:horde, "~> 0.9"},
      {:finch, "~> 0.19"},
      {:broadway, "~> 1.1"},
      {:plug, "~> 1.16"},
      {:telemetry, "~> 1.2"}
    ]
  end
end
