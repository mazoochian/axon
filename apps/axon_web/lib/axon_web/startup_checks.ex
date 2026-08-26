defmodule AxonWeb.StartupChecks do
  @moduledoc """
  Boot-time warnings for configuration that is legal, deliberately
  supported, and a bad idea in a real deployment.

  Two different things already fail loudly and belong nowhere near here:
  a *missing* required secret (`config/runtime.exs` raises on
  `SECRET_KEY_BASE`/`DB_PASS`), and a *dangerous* default that was simply
  removed (the shared-secret admin bootstrap answers 404 unless a
  per-deployment secret is set). What's left is the awkward middle — knobs
  that exist because Complement or a throwaway instance genuinely needs
  them, that are perfectly correct in dev/test, and that quietly gut a
  production server if they leak into one. Those can't be made to fail;
  the only remaining defence is that the operator can find out.

  So: every check here is prod-only (`:axon_web, :env` — see
  config/config.exs for why `Mix.env/0` can't be used from a release), and
  every check warns rather than raises. A server that boots with these on
  is a server the operator chose to run that way; a server that boots with
  these on *silently* is an accident.

  `warnings/0` returns the messages instead of logging them so a test can
  assert on the conditions without capturing logs and without a running
  application; `run/0` is what `AxonWeb.Application.start/2` calls.
  """

  require Logger

  @doc "Logs one warning per risky-but-legal production setting. Returns :ok."
  def run do
    Enum.each(warnings(), &Logger.warning/1)
    :ok
  end

  @doc """
  The warnings that apply to the current configuration, in a stable order.
  Always `[]` outside `:prod`, where every one of these settings is either
  the intended default or actively required by the test suite.
  """
  @spec warnings() :: [String.t()]
  def warnings do
    if Application.get_env(:axon_web, :env) == :prod do
      Enum.flat_map([&relaxed_rate_limits/0, &ephemeral_signing_key/0], & &1.())
    else
      []
    end
  end

  # RELAXED_RATE_LIMITS sets every bucket to 1,000,000 — which is to say,
  # off. It exists for Complement, whose harness legitimately registers and
  # sends far faster than any anti-abuse limit would allow. On a real
  # deployment it removes the only throttle on login guessing, registration
  # flooding and the password-verifying UIA endpoints at once.
  defp relaxed_rate_limits do
    if Application.get_env(:axon_web, :relaxed_rate_limits) == true do
      [
        "RELAXED_RATE_LIMITS=true is set in a production build: every rate limit " <>
          "(login, register, send, media upload, UIA password checks, refresh) is " <>
          "effectively disabled. This exists for the Complement compliance harness " <>
          "and must not be set on a deployment reachable by anyone else."
      ]
    else
      []
    end
  end

  # No SIGNING_KEY_PATH means AxonCrypto.KeyServer mints a fresh in-memory
  # Ed25519 identity on every boot. That is the right behavior for dev, test
  # and CI, and it is a broken federation identity for anything long-lived:
  # every `/_matrix/key/v2/server` response other servers cached becomes
  # wrong, and every signature they already verified stops verifying against
  # the key this server now advertises.
  defp ephemeral_signing_key do
    if is_nil(Application.get_env(:axon_crypto, :signing_key_path)) do
      [
        "SIGNING_KEY_PATH is not set in a production build: this server's Ed25519 " <>
          "federation identity is generated in memory and is regenerated on every " <>
          "restart, invalidating every cached /_matrix/key/v2/server response and " <>
          "every signature a remote server has already verified. Point it at a file " <>
          "on persistent, backed-up storage."
      ]
    else
      []
    end
  end
end
