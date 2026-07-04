defmodule AxonPush.MixProject do
  use Mix.Project

  def project do
    [
      app: :axon_push,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AxonPush.Application, []}
    ]
  end

  defp deps do
    [
      {:axon_core, in_umbrella: true},
      {:finch, "~> 0.19"},
      {:telemetry, "~> 1.2"},
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
