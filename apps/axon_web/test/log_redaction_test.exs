defmodule AxonWeb.LogRedactionTest do
  @moduledoc """
  Phoenix logs every request's parameters ("Processing with ... Parameters:
  ...") at `:info`, and this API's parameters include passwords, access
  tokens and the shared-secret bootstrap's HMAC. No
  `config :phoenix, :filter_parameters` was ever set (audit I1), so
  Phoenix's own default of `["password"]` applied and everything else went
  to the log verbatim — including the `?access_token=` query parameter the
  spec still permits and real clients still use (audit L2), which is why
  the two findings share one fix.

  These run the real router with the log level temporarily raised to
  `:info` and assert on the bytes Phoenix actually emitted, rather than on
  the config list — the config is only interesting if it reaches the log
  line, and `filter_values/1` matching is by *substring* on the parameter
  name, which is easy to get subtly wrong.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers
  import ExUnit.CaptureLog

  # config/test.exs pins the level at :warning so the suite isn't drowned in
  # request logs. The "Processing with ... Parameters:" line — the only one
  # that carries request parameters at all — is emitted by
  # `Phoenix.Logger.phoenix_router_dispatch_start/4` at the router's `:log`
  # level, which defaults to `:debug`, so that's what has to be lifted here.
  defp capture_request(fun) do
    original = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log(fun)
    after
      Logger.configure(level: original)
    end
  end

  test "a password in a login body is not written to the log" do
    username = "logredact_#{System.unique_integer([:positive])}"
    register(username)

    log =
      capture_request(fn ->
        build_conn()
        |> jp("/_matrix/client/v3/login", %{
          "type" => "m.login.password",
          "identifier" => %{"type" => "m.id.user", "user" => username},
          "password" => "hunter2-should-never-be-logged"
        })
      end)

    assert log =~ "Parameters:"
    refute log =~ "hunter2-should-never-be-logged"
    assert log =~ "[FILTERED]"

    # The non-secret parts are still there — this is redaction, not
    # blanket suppression, and a request log with nothing identifying in
    # it is no use to whoever is reading it at 3am.
    assert log =~ username
  end

  test "an access token in the query string is not written to the log" do
    user = register("logredact_qs_#{System.unique_integer([:positive])}")

    log =
      capture_request(fn ->
        conn = build_conn() |> get("/_matrix/client/v3/account/whoami?access_token=#{user.token}")
        assert conn.status == 200
      end)

    refute log =~ user.token
    assert log =~ "[FILTERED]"
  end

  test "an access token in the Authorization header is not written to the log either" do
    # Headers aren't logged at all, but this is the path everything else
    # uses, so it's worth pinning: no configuration change should ever start
    # putting them in.
    user = register("logredact_hdr_#{System.unique_integer([:positive])}")

    log =
      capture_request(fn ->
        conn = authed(user.token) |> get("/_matrix/client/v3/account/whoami")
        assert conn.status == 200
      end)

    refute log =~ user.token
  end

  test "the shared-secret admin bootstrap's MAC is not written to the log" do
    mac = "deadbeef" <> String.duplicate("0", 32)

    log =
      capture_request(fn ->
        build_conn()
        |> jp("/_synapse/admin/v1/register", %{
          "nonce" => "abc123",
          "username" => "logredact_admin_#{System.unique_integer([:positive])}",
          "password" => "a-password-that-must-not-be-logged",
          "mac" => mac,
          "admin" => true
        })
      end)

    refute log =~ mac
    refute log =~ "a-password-that-must-not-be-logged"
  end

  test "the configured filter list covers the credential-shaped parameter names" do
    # Note this calls `filter_values/1`, not `/2`: Phoenix compiles
    # `:filter_parameters` into a `{:compiled, key_match, value_match}`
    # tuple in application env at boot, so reading the config back and
    # asserting it's the list that was written finds a tuple and proves
    # nothing. What matters is what the *effective, live* filter does,
    # which is what the request logger uses.
    filtered =
      Phoenix.Logger.filter_values(%{
        "password" => "p",
        "new_password" => "p",
        "access_token" => "t",
        "refresh_token" => "t",
        "id_access_token" => "t",
        "mac" => "m",
        "client_secret" => "s",
        "user" => "@alice:localhost",
        "room_id" => "!r:localhost",
        "state_key" => "@alice:localhost"
      })

    for key <-
          ~w(password new_password access_token refresh_token id_access_token mac client_secret) do
      assert filtered[key] == "[FILTERED]", "#{key} was not filtered"
    end

    # Deliberately still visible: these are what makes a request log
    # readable, and none of them is a credential.
    assert filtered["user"] == "@alice:localhost"
    assert filtered["room_id"] == "!r:localhost"
    assert filtered["state_key"] == "@alice:localhost"
  end
end
