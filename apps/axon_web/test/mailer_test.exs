defmodule AxonWeb.MailerTest do
  @moduledoc """
  Tests `AxonWeb.Mailer.deliver_3pid_invite/2`'s real outbound SMTP
  delivery against a fake SMTP server (`AxonWeb.FakeSmtpServer`), and its
  no-op behavior when SMTP isn't configured.
  """

  use ExUnit.Case, async: false

  alias AxonWeb.{FakeSmtpServer, Mailer}

  @port 18_600

  setup do
    previous = Application.get_env(:axon_web, :smtp)

    on_exit(fn ->
      if previous do
        Application.put_env(:axon_web, :smtp, previous)
      else
        Application.delete_env(:axon_web, :smtp)
      end
    end)

    :ok
  end

  defp configure_smtp do
    start_supervised!({FakeSmtpServer, port: @port})

    Application.put_env(:axon_web, :smtp,
      relay: "127.0.0.1",
      port: @port,
      username: nil,
      password: nil,
      tls: :never,
      from: "no-reply@test.local"
    )
  end

  defp wait_for_delivery(retries \\ 50) do
    case FakeSmtpServer.received(@port) do
      [] when retries > 0 ->
        Process.sleep(20)
        wait_for_delivery(retries - 1)

      received ->
        received
    end
  end

  test "delivers an email with the invite details when SMTP is configured" do
    configure_smtp()

    Mailer.deliver_3pid_invite("bob@example.com", %{
      inviter_id: "@alice:localhost",
      room_id: "!room:localhost",
      token: "tok_abc123"
    })

    [msg] = wait_for_delivery()
    assert msg.from == "no-reply@test.local"
    assert msg.to == ["bob@example.com"]
    assert msg.data =~ "tok_abc123"
    assert msg.data =~ "!room:localhost"
    assert msg.data =~ "@alice:localhost"
  end

  test "is a silent no-op when SMTP is not configured" do
    Application.put_env(:axon_web, :smtp, relay: nil)

    assert Mailer.deliver_3pid_invite("bob@example.com", %{
             inviter_id: "@alice:localhost",
             room_id: "!room:localhost",
             token: "tok_xyz"
           }) == :ok

    # No fake server is even started, so any attempted delivery would
    # crash the caller (connection refused) rather than silently pass —
    # give the (nonexistent) fire-and-forget task a moment either way.
    Process.sleep(100)
  end

  test "configured?/0 reflects whether SMTP_HOST-equivalent config is set" do
    Application.put_env(:axon_web, :smtp, relay: nil)
    refute Mailer.configured?()

    configure_smtp()
    assert Mailer.configured?()
  end
end
