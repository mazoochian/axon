defmodule AxonWeb.ProdConfigTest do
  @moduledoc """
  Production config must fail loudly rather than fall back to a guessable
  secret.

  `config/prod.exs` used to default `secret_key_base` to
  `String.duplicate("a", 64)` and `DB_PASS` to `"axon"`. `secret_key_base`
  keys every `Plug.Crypto`-signed cookie, CSRF token and `Phoenix.Token` the
  server issues, so a value published in this repo is a forgery key for all
  of them — and `.env.example` shipping `SECRET_KEY_BASE=` blank made an
  insecure deploy the *default* outcome for anyone following the README.

  These read the real config files with `Config.Reader` (which evaluates
  them exactly as boot does, but returns the keyword list instead of
  applying it) rather than asserting on their text.
  """

  use ExUnit.Case, async: false

  @config_dir Path.expand("../../../config", __DIR__)

  defp runtime_config(env_overrides) do
    original = Enum.map(env_overrides, fn {k, _} -> {k, System.get_env(k)} end)

    Enum.each(env_overrides, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    try do
      Config.Reader.read!(Path.join(@config_dir, "runtime.exs"), env: :prod)
    after
      Enum.each(original, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  @required %{
    "SECRET_KEY_BASE" => String.duplicate("z", 64),
    "DB_PASS" => "a-real-password",
    "SERVER_NAME" => "matrix.example.com"
  }

  describe "runtime.exs in :prod" do
    test "refuses to boot without SECRET_KEY_BASE" do
      assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn ->
        runtime_config(Map.put(@required, "SECRET_KEY_BASE", nil))
      end
    end

    test "refuses to boot without DB_PASS" do
      assert_raise RuntimeError, ~r/DB_PASS/, fn ->
        runtime_config(Map.put(@required, "DB_PASS", nil))
      end
    end

    test "uses the supplied secret verbatim, with no fallback anywhere in the tree" do
      config = runtime_config(@required)

      assert get_in(config, [:axon_web, AxonWeb.Endpoint, :secret_key_base]) ==
               @required["SECRET_KEY_BASE"]

      assert get_in(config, [:axon_web, AxonWeb.FederationEndpoint, :secret_key_base]) ==
               @required["SECRET_KEY_BASE"]

      assert get_in(config, [:axon_core, AxonCore.Repo, :password]) == @required["DB_PASS"]
      assert get_in(config, [:axon_core, AxonCore.AdvisoryLockRepo, :password]) ==
               @required["DB_PASS"]
    end

    test "the shared-secret admin bootstrap is off unless REGISTRATION_SHARED_SECRET is set" do
      config = runtime_config(Map.put(@required, "REGISTRATION_SHARED_SECRET", nil))
      assert get_in(config, [:axon_web, :registration_shared_secret]) == nil

      config =
        runtime_config(Map.put(@required, "REGISTRATION_SHARED_SECRET", "per-deployment-secret"))

      assert get_in(config, [:axon_web, :registration_shared_secret]) == "per-deployment-secret"
    end

    test "the media SSRF guard is on unless explicitly disabled" do
      config = runtime_config(Map.put(@required, "FEDERATION_ALLOW_PRIVATE_ADDRESSES", nil))
      assert get_in(config, [:axon_federation, :allow_private_addresses]) == false

      config = runtime_config(Map.put(@required, "FEDERATION_ALLOW_PRIVATE_ADDRESSES", "true"))
      assert get_in(config, [:axon_federation, :allow_private_addresses]) == true
    end
  end

  describe "prod.exs" do
    # Compile-time config is baked into a release and silently wins wherever
    # runtime.exs hasn't overridden it — so it must carry no secret at all,
    # not merely a "better" default.
    test "supplies no secret_key_base and no database password of its own" do
      config = Config.Reader.read!(Path.join(@config_dir, "prod.exs"), env: :prod)

      endpoint = get_in(config, [:axon_web, AxonWeb.Endpoint]) || []
      refute Keyword.has_key?(endpoint, :secret_key_base)

      repo = get_in(config, [:axon_core, AxonCore.Repo]) || []
      refute Keyword.has_key?(repo, :password)
    end
  end

  describe "config.exs" do
    test "the last-resort endpoint secret is not a fixed literal" do
      first = Config.Reader.read!(Path.join(@config_dir, "config.exs"), env: :prod)
      second = Config.Reader.read!(Path.join(@config_dir, "config.exs"), env: :prod)

      a = get_in(first, [:axon_web, AxonWeb.Endpoint, :secret_key_base])
      b = get_in(second, [:axon_web, AxonWeb.Endpoint, :secret_key_base])

      # A caller who has read this repo must not be able to predict it.
      refute a == String.duplicate("a", 64)
      refute a == b
    end
  end

  describe ".env.example" do
    test "ships no usable placeholder for the values that must be set" do
      example = File.read!(Path.expand("../../../.env.example", __DIR__))

      # Blank, not "changeme" — a placeholder that looks like a value is
      # exactly what gets deployed as-is.
      assert example =~ ~r/^SECRET_KEY_BASE=\s*$/m
      assert example =~ ~r/^DB_PASS=\s*$/m
      refute example =~ ~r/^DB_PASS=changeme\s*$/m
    end
  end
end
