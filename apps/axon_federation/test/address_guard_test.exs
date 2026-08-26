defmodule AxonFederation.AddressGuardTest do
  @moduledoc """
  The SSRF guard on remote-media fetching (`AxonFederation.AddressGuard`,
  applied via `AxonFederation.ServerResolver.resolve_checked/1`).

  The `:server_name` these fetches connect to is a path segment of
  `/_matrix/media/v3/download/:server_name/:media_id` — an endpoint that
  takes no authentication at all — so before this guard existed, an
  anonymous caller could name any `host:port` and make the homeserver dial
  it: cloud instance metadata on 169.254.169.254, Postgres on loopback, an
  internal admin panel, anything trusting the homeserver's source IP.

  The load-bearing assertions here are made against a **real listening
  socket**: the point isn't that an error is returned, it's that no packet
  ever reaches the attacker's port. Each test binds a `:gen_tcp` listener on
  loopback and then asserts on whether `:gen_tcp.accept/2` sees a
  connection — the same observation the original audit made when it caught
  Axon opening a TLS connection to its listener.
  """

  use ExUnit.Case, async: false

  alias AxonFederation.{AddressGuard, MediaFetch, ServerResolver}

  setup do
    previous = Application.get_env(:axon_federation, :allow_private_addresses)
    # config/test.exs turns the guard off for the suite at large (every fake
    # remote server in it is a loopback Bandit listener). These tests are
    # about the guard, so they turn it back on.
    Application.put_env(:axon_federation, :allow_private_addresses, false)
    on_exit(fn -> Application.put_env(:axon_federation, :allow_private_addresses, previous) end)
    :ok
  end

  # A bound-but-unserved TCP port on loopback: the "internal service" an
  # attacker is trying to reach.
  defp internal_listener do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    {socket, port}
  end

  describe "server_name checking" do
    test "blocks loopback, RFC1918, link-local, ULA, multicast and IPv4-mapped literals" do
      blocked = [
        "127.0.0.1",
        "127.0.0.1:9098",
        "10.0.0.5:8448",
        "172.16.4.1",
        "172.31.255.255",
        "192.168.1.1:8448",
        # Cloud instance metadata — the single most valuable SSRF target.
        "169.254.169.254",
        "0.0.0.0",
        "100.64.0.1",
        "224.0.0.1",
        "[::1]",
        "[::1]:8448",
        "[fe80::1]",
        "[fc00::1]",
        "[::ffff:127.0.0.1]",
        "localhost",
        "localhost:8448"
      ]

      for server_name <- blocked do
        assert {:error, :blocked_address} = AddressGuard.check_server_name(server_name),
               "expected #{server_name} to be blocked"
      end
    end

    test "allows an ordinary public address" do
      assert :ok = AddressGuard.check_server_name("93.184.216.34")
      assert :ok = AddressGuard.check_server_name("93.184.216.34:8448")
      assert :ok = AddressGuard.check_server_name("[2606:2800:220:1:248:1893:25c8:1946]:8448")
    end

    test "an unresolvable name is blocked, not passed through" do
      assert {:error, :blocked_address} =
               AddressGuard.check_server_name("no-such-host.invalid")
    end

    test "the IPv6 bracket form isn't mistaken for a host:port split" do
      # "[::1]:8448" must parse as host "[::1]" port 8448, not host "[".
      assert {:error, :blocked_address} = AddressGuard.check_server_name("[::1]:8448")
      assert :ok = AddressGuard.check_server_name("[2001:4860:4860::8888]")
    end

    test "check_base_url/1 catches a private host reached via a resolved base URL" do
      assert {:error, :blocked_address} = AddressGuard.check_base_url("https://127.0.0.1:5432")
      assert {:error, :blocked_address} = AddressGuard.check_base_url("http://169.254.169.254/")
      assert {:error, :blocked_address} = AddressGuard.check_base_url("not a url")
      assert :ok = AddressGuard.check_base_url("https://93.184.216.34:8448")
    end

    test "resolve_checked/1 refuses a private server_name and resolves a public one" do
      assert {:error, :blocked_address} = ServerResolver.resolve_checked("127.0.0.1:9098")
      assert {:ok, "https://93.184.216.34:8448"} = ServerResolver.resolve_checked("93.184.216.34:8448")
    end
  end

  describe "no connection is opened to a blocked target" do
    test "download/2 never dials the attacker's port" do
      {socket, port} = internal_listener()

      assert {:error, :blocked_address} =
               MediaFetch.download("127.0.0.1:#{port}", "AAAAAAAAAAAAAAAAAAAAAAAA")

      assert {:error, :timeout} = :gen_tcp.accept(socket, 300)
    end

    test "thumbnail/3 never dials the attacker's port" do
      {socket, port} = internal_listener()

      assert {:error, :blocked_address} =
               MediaFetch.thumbnail("127.0.0.1:#{port}", "AAAAAAAAAAAAAAAAAAAAAAAA", %{
                 "width" => "32",
                 "height" => "32"
               })

      assert {:error, :timeout} = :gen_tcp.accept(socket, 300)
    end

    # The control: the same call with the guard switched off *does* reach the
    # listener. Without this, "no connection" above would also pass if the
    # request were failing for some unrelated reason.
    test "with the guard disabled, the same request does reach the listener" do
      Application.put_env(:axon_federation, :allow_private_addresses, true)
      {socket, port} = internal_listener()

      accepted =
        Task.async(fn ->
          case :gen_tcp.accept(socket, 5_000) do
            {:ok, client} ->
              :gen_tcp.close(client)
              :connected

            {:error, :timeout} ->
              :no_connection
          end
        end)

      # Errors out (the listener hangs up mid-handshake) — the point is only
      # that the connection was made at all.
      assert {:error, _} = MediaFetch.download("127.0.0.1:#{port}", "AAAAAAAAAAAAAAAAAAAAAAAA")
      assert Task.await(accepted, 10_000) == :connected
    end
  end
end
