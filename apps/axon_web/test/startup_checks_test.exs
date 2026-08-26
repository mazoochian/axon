defmodule AxonWeb.StartupChecksTest do
  @moduledoc """
  `AxonWeb.StartupChecks` — the boot-time warnings for settings that are
  legal, supported, and wrong for a real deployment (audit L1's
  `RELAXED_RATE_LIMITS` escape hatch and I2's ephemeral signing key).

  Neither can be made to fail closed: Complement needs the first, and every
  dev/test/CI run depends on the second. The whole value is that an
  operator can find out, so what's asserted here is that the warning is
  actually emitted, that it names the environment variable an operator
  would search for, and — just as important — that it stays silent
  everywhere it would otherwise fire on every single test run.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AxonWeb.StartupChecks

  setup do
    original_env = Application.get_env(:axon_web, :env)
    original_relaxed = Application.get_env(:axon_web, :relaxed_rate_limits)
    original_key_path = Application.get_env(:axon_crypto, :signing_key_path)

    on_exit(fn ->
      put_or_delete(:axon_web, :env, original_env)
      put_or_delete(:axon_web, :relaxed_rate_limits, original_relaxed)
      put_or_delete(:axon_crypto, :signing_key_path, original_key_path)
    end)

    :ok
  end

  defp put_or_delete(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete(app, key, value), do: Application.put_env(app, key, value)

  defp prod!(opts) do
    Application.put_env(:axon_web, :env, :prod)

    case Keyword.get(opts, :relaxed) do
      nil -> Application.delete_env(:axon_web, :relaxed_rate_limits)
      v -> Application.put_env(:axon_web, :relaxed_rate_limits, v)
    end

    case Keyword.get(opts, :signing_key_path) do
      nil -> Application.delete_env(:axon_crypto, :signing_key_path)
      v -> Application.put_env(:axon_crypto, :signing_key_path, v)
    end
  end

  describe "in :prod" do
    test "warns when RELAXED_RATE_LIMITS turned every limit off" do
      prod!(relaxed: true, signing_key_path: "/srv/axon/signing.key")

      assert [warning] = StartupChecks.warnings()
      assert warning =~ "RELAXED_RATE_LIMITS"
      assert warning =~ "Complement"
    end

    test "warns when no SIGNING_KEY_PATH was configured" do
      prod!(relaxed: nil, signing_key_path: nil)

      assert [warning] = StartupChecks.warnings()
      assert warning =~ "SIGNING_KEY_PATH"
      assert warning =~ "restart"
    end

    test "warns about both at once, and about neither when both are configured properly" do
      prod!(relaxed: true, signing_key_path: nil)
      assert length(StartupChecks.warnings()) == 2

      prod!(relaxed: nil, signing_key_path: "/srv/axon/signing.key")
      assert StartupChecks.warnings() == []
    end

    test "an explicit RELAXED_RATE_LIMITS=false is not a warning" do
      # config/runtime.exs only sets the flag when the variable is exactly
      # "true", but a stale `false` left in Application env must not warn
      # either — the warning is about limits actually being off.
      prod!(relaxed: false, signing_key_path: "/srv/axon/signing.key")
      assert StartupChecks.warnings() == []
    end

    test "run/0 logs each warning at :warning level" do
      prod!(relaxed: true, signing_key_path: nil)

      log = capture_log(fn -> assert :ok == StartupChecks.run() end)

      assert log =~ "RELAXED_RATE_LIMITS"
      assert log =~ "SIGNING_KEY_PATH"
      assert log =~ "[warning]"
    end
  end

  describe "outside :prod" do
    # Both conditions hold on literally every dev and test run — an
    # unconditional warning would be noise that trains everyone to ignore
    # the one place it matters.
    test "says nothing, even with both risky settings in force" do
      Application.put_env(:axon_web, :env, :test)
      Application.put_env(:axon_web, :relaxed_rate_limits, true)
      Application.delete_env(:axon_crypto, :signing_key_path)

      assert StartupChecks.warnings() == []

      log = capture_log(fn -> StartupChecks.run() end)
      refute log =~ "RELAXED_RATE_LIMITS"
      refute log =~ "SIGNING_KEY_PATH"
    end

    test "the real test environment is quiet as configured" do
      assert Application.get_env(:axon_web, :env) == :test
      assert StartupChecks.warnings() == []
    end
  end
end
