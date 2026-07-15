defmodule AxonWeb.AppService.ManagerTest do
  @moduledoc """
  Direct unit tests for `AxonWeb.AppService.Manager`, previously entirely
  untested. The manager is a singleton GenServer started by the application
  supervisor with an empty registration set (no `appservices.json` in the
  test environment) — its backing ETS table (`:axon_appservices`) is
  `:public` and `:named_table`, so tests write registrations directly into
  it rather than restarting the process, then either call the pure
  `verify_as_token/1`/`verify_hs_token/1` reads directly or send a
  `{:new_event, room_id, event_map}` message (what `Phoenix.PubSub` would
  otherwise deliver) to exercise the dispatch path against a real local
  receiver standing in for the appservice.
  """

  use ExUnit.Case, async: false

  alias AxonWeb.AppService.Manager

  @table :axon_appservices

  defp put_registrations(regs) do
    :ets.insert(@table, {:registrations, regs})
    on_exit_restore()
  end

  defp on_exit_restore do
    ExUnit.Callbacks.on_exit(fn -> :ets.insert(@table, {:registrations, []}) end)
  end

  setup do
    :ets.insert(@table, {:registrations, []})
    :ok
  end

  describe "verify_as_token/1 and verify_hs_token/1" do
    test "verify_as_token finds a matching registration" do
      reg = %{"id" => "bridge1", "as_token" => "as-secret-1", "hs_token" => "hs-secret-1"}
      put_registrations([reg])

      assert Manager.verify_as_token("as-secret-1") == {:ok, reg}
    end

    test "verify_as_token returns :error for an unknown token" do
      put_registrations([%{"id" => "bridge1", "as_token" => "as-secret-1"}])
      assert Manager.verify_as_token("nope") == :error
    end

    test "verify_hs_token finds a matching registration" do
      reg = %{"id" => "bridge1", "as_token" => "as-secret-1", "hs_token" => "hs-secret-1"}
      put_registrations([reg])

      assert Manager.verify_hs_token("hs-secret-1") == {:ok, reg}
    end

    test "verify_hs_token returns :error for an unknown token" do
      put_registrations([%{"id" => "bridge1", "hs_token" => "hs-secret-1"}])
      assert Manager.verify_hs_token("nope") == :error
    end
  end

  describe "event dispatch (handle_info {:new_event, ...})" do
    setup do
      port = 18_900 + :erlang.unique_integer([:positive, :monotonic])
      Agent.start_link(fn -> [] end, name: receiver_name(port))

      {:ok, pid} =
        Bandit.start_link(plug: {__MODULE__.ReceiverPlug, port}, ip: {127, 0, 0, 1}, port: port)

      on_exit(fn -> Process.exit(pid, :kill) end)
      %{port: port}
    end

    defp receiver_name(port), do: :"as_manager_test_receiver_#{port}"
    defp received(port), do: Agent.get(receiver_name(port), & &1)

    test "an event from a matching user namespace is delivered to the appservice", %{port: port} do
      reg = %{
        "id" => "bridge_user",
        "url" => "http://127.0.0.1:#{port}",
        "hs_token" => "hs-tok",
        "namespaces" => %{
          "users" => [%{"regex" => "@bridge_.*", "exclusive" => true}],
          "rooms" => []
        }
      }

      put_registrations([reg])

      event = %{
        "type" => "m.room.message",
        "sender" => "@bridge_bot:localhost",
        "content" => %{"body" => "hi"}
      }

      send(Manager, {:new_event, "!room:localhost", event})

      assert wait_for(fn -> received(port) != [] end)
      [delivered] = received(port)
      [sent_event] = delivered["events"]
      assert sent_event["sender"] == "@bridge_bot:localhost"
      assert sent_event["room_id"] == "!room:localhost"
    end

    test "an event from a matching room namespace is delivered to the appservice", %{port: port} do
      reg = %{
        "id" => "bridge_room",
        "url" => "http://127.0.0.1:#{port}",
        "hs_token" => "hs-tok",
        "namespaces" => %{
          "users" => [],
          "rooms" => [%{"regex" => "!bridged_.*", "exclusive" => true}]
        }
      }

      put_registrations([reg])

      event = %{"type" => "m.room.message", "sender" => "@someone:localhost", "content" => %{}}
      send(Manager, {:new_event, "!bridged_abc:localhost", event})

      assert wait_for(fn -> received(port) != [] end)
    end

    test "an event matching no namespace is not delivered", %{port: port} do
      reg = %{
        "id" => "bridge_none",
        "url" => "http://127.0.0.1:#{port}",
        "hs_token" => "hs-tok",
        "namespaces" => %{"users" => [%{"regex" => "@bridge_.*"}], "rooms" => []}
      }

      put_registrations([reg])

      event = %{"type" => "m.room.message", "sender" => "@unrelated:localhost", "content" => %{}}
      send(Manager, {:new_event, "!room:localhost", event})

      refute wait_for(fn -> received(port) != [] end, 300)
      assert received(port) == []
    end

    test "an unparseable namespace regex never matches, instead of crashing dispatch", %{
      port: port
    } do
      reg = %{
        "id" => "bridge_badregex",
        "url" => "http://127.0.0.1:#{port}",
        "hs_token" => "hs-tok",
        "namespaces" => %{"users" => [%{"regex" => "("}], "rooms" => []}
      }

      put_registrations([reg])

      event = %{"type" => "m.room.message", "sender" => "@anyone:localhost", "content" => %{}}
      send(Manager, {:new_event, "!room:localhost", event})

      refute wait_for(fn -> received(port) != [] end, 300)
    end

    test "no registered appservices means nothing is dispatched (no crash)" do
      put_registrations([])

      send(
        Manager,
        {:new_event, "!room:localhost", %{"type" => "m.room.message", "sender" => "@x:localhost"}}
      )

      Process.sleep(50)
      assert Process.alive?(Process.whereis(Manager))
    end

    test "an unrecognized message is ignored without crashing" do
      pid = Process.whereis(Manager)
      send(Manager, :some_other_message)
      Process.sleep(20)
      assert Process.alive?(pid)
    end
  end

  defp wait_for(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        do_wait_for(fun, deadline)
    end
  end

  defmodule ReceiverPlug do
    @behaviour Plug

    def init(port), do: port

    def call(conn, port) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      Agent.update(:"as_manager_test_receiver_#{port}", fn list -> list ++ [decoded] end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")
    end
  end
end
