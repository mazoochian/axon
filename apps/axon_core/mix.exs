defmodule AxonCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :axon_core,
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
      mod: {AxonCore.Application, []}
    ]
  end

  defp deps do
    [
      {:axon_crypto, in_umbrella: true},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"},
      {:argon2_elixir, "~> 4.0"}
    ]
  end
end
