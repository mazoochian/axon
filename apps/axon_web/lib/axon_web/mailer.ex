defmodule AxonWeb.Mailer do
  @moduledoc """
  Best-effort SMTP delivery for 3pid (email) invites.

  Previously a documented gap — `RoomController.invite_3pid/4` built a
  fully real, spec-shaped `m.room.third_party_invite` (self-signed proof
  and all), but nothing ever told the invitee it existed; the token had
  to reach them out-of-band. This closes that for email specifically —
  SMS would need a paid third-party API (Twilio or similar) this project
  has no account for, so it's left as-is.

  Uses `:gen_smtp` directly (a focused SMTP client, not a full mailer
  framework with templating/multi-provider abstraction this project has
  no use for — one plain-text message, one path) rather than hand-rolling
  SMTP: STARTTLS negotiation and AUTH are exactly the kind of
  security-sensitive protocol code not worth re-implementing for a
  single use site.

  Fully optional and off by default — unset `SMTP_HOST` (same pattern as
  `AxonWeb.Oidc`/Sentry in `config/runtime.exs`) and `deliver_3pid_invite/2`
  is a silent no-op, matching the pre-existing "out-of-band" behavior
  exactly. Delivery is fire-and-forget (a spawned `Task`, matching
  `AxonWeb.AppService.Manager`'s own dispatch-to-external-service
  pattern): a slow or unreachable SMTP relay must never block the
  inviter's `/invite` request, and there is no retry queue — this is
  best-effort notification, not guaranteed delivery, the same tradeoff
  `AxonFederation.OutboundQueue` explicitly does NOT make for federation
  traffic (that one matters enough to retry; a courtesy email doesn't).
  """

  require Logger

  @doc "Configured at all — false lets a caller skip building content that would never be sent."
  def configured? do
    smtp_config()[:relay] != nil
  end

  @doc """
  Sends a plain-text notification to `address` (an email address; the
  medium is assumed already checked by the caller) that `inviter_id` has
  invited them to `room_id` on this server, with the raw 3pid-invite
  `token` needed to complete the join via `POST /join` per the 3pid
  invite flow (AuthRules rule 7). No-op (logged at debug, not warned —
  this is the expected, common case) when SMTP isn't configured.
  """
  def deliver_3pid_invite(address, %{inviter_id: _, room_id: _, token: _} = invite) do
    case smtp_config() do
      %{relay: nil} ->
        Logger.debug("SMTP not configured — skipping 3pid invite email to #{obscure(address)}")
        :ok

      config ->
        Task.start(fn -> send_invite_email(address, invite, config) end)
        :ok
    end
  end

  defp send_invite_email(address, %{inviter_id: inviter_id, room_id: room_id, token: token}, config) do
    server_name = AxonCrypto.KeyServer.server_name()
    subject = "#{inviter_id} invited you to chat on #{server_name}"

    body = """
    Subject: #{subject}
    From: #{config.from}
    To: #{address}
    Content-Type: text/plain; charset=utf-8
    MIME-Version: 1.0

    #{inviter_id} has invited you to join a room on the #{server_name} Matrix server.

    To accept, use a Matrix client that supports 3pid invites, or complete the
    invite manually with this room and token:

      Room: #{room_id}
      Token: #{token}
      Server: #{server_name}
    """

    result =
      :gen_smtp_client.send_blocking(
        {config.from, [address], String.replace(body, "\n", "\r\n")},
        gen_smtp_options(config)
      )

    case result do
      {:error, type, message} ->
        Logger.warning("3pid invite email to #{obscure(address)} failed: #{type} #{inspect(message)}")

      {:error, reason} ->
        Logger.warning("3pid invite email to #{obscure(address)} failed: #{inspect(reason)}")

      _receipt ->
        :ok
    end
  end

  defp gen_smtp_options(config) do
    [
      relay: String.to_charlist(config.relay),
      port: config.port,
      hostname: String.to_charlist(AxonCrypto.KeyServer.server_name()),
      auth: if(config.username, do: :always, else: :never),
      username: config.username && String.to_charlist(config.username),
      password: config.password && String.to_charlist(config.password),
      tls: config.tls,
      no_mx_lookups: true
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp smtp_config do
    Application.get_env(:axon_web, :smtp, relay: nil) |> Map.new()
  end

  # Never let an SMTP delivery failure log the invitee's actual address —
  # same spirit as RoomController.obfuscate_3pid/2, which already never
  # shows the full address in the m.room.third_party_invite event either.
  defp obscure(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] -> String.slice(local, 0, 1) <> "***@" <> domain
      _ -> "***"
    end
  end
end
