defmodule AxonCrypto.KeyServerTest do
  @moduledoc """
  Direct unit tests for `AxonCrypto.KeyServer` — previously only ever
  exercised indirectly through other apps' integration tests (it has no
  supervision tree of its own in axon_crypto, so nothing here started it
  before now).
  """

  use ExUnit.Case, async: true

  alias AxonCrypto.{CanonicalJSON, EventHash, KeyServer}

  setup do
    name = :"key_server_test_#{System.unique_integer([:positive])}"
    server_name = "test-server-#{System.unique_integer([:positive])}.example.org"

    # KeyServer registers itself under its own module name (not the `name`
    # option), so tests must run isolated GenServers directly rather than
    # through the public API, which always targets AxonCrypto.KeyServer.
    {:ok, pid} = GenServer.start_link(KeyServer, [server_name: server_name], name: name)
    %{pid: pid, server_name: server_name}
  end

  describe "generate_keypair/0" do
    test "returns a well-formed key_id and 32-byte Ed25519 keys" do
      {key_id, public_key, private_key} = KeyServer.generate_keypair()

      assert String.starts_with?(key_id, "ed25519:")
      assert byte_size(public_key) == 32
      assert byte_size(private_key) == 32
    end

    test "generates distinct keys on every call" do
      {id1, pub1, _} = KeyServer.generate_keypair()
      {id2, pub2, _} = KeyServer.generate_keypair()

      refute id1 == id2
      refute pub1 == pub2
    end
  end

  describe "server_name/0" do
    test "returns the configured server name", %{pid: pid, server_name: server_name} do
      assert GenServer.call(pid, :server_name) == server_name
    end
  end

  describe "server_key_info/0 (via handle_call)" do
    test "returns a self-signed key document verifiable against its own public key", %{
      pid: pid,
      server_name: server_name
    } do
      info = GenServer.call(pid, :server_key_info)

      assert info.server_name == server_name
      assert String.starts_with?(info.key_id, "ed25519:")
      assert is_binary(info.public_key_b64)
      assert info.valid_until_ts > System.os_time(:millisecond)

      sig_b64 = info.signatures[server_name][info.key_id]
      assert is_binary(sig_b64)

      # Reconstruct the *actual* document AxonWeb.KeyController.server_keys/2
      # serves for GET /_matrix/key/v2/server (see key_controller.ex) and
      # verify the signature against exactly that — not some subset of it.
      # Regression: the signature used to be computed over a document
      # missing "old_verify_keys", which every real client only ever sees
      # combined with that field, so it never verified for anyone but this
      # test (which used to reconstruct the same incomplete document).
      unsigned_doc = %{
        "server_name" => info.server_name,
        "valid_until_ts" => info.valid_until_ts,
        "verify_keys" => %{info.key_id => %{"key" => info.public_key_b64}},
        "old_verify_keys" => %{}
      }

      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)
      {:ok, sig_bytes} = Base.decode64(sig_b64, padding: false)
      payload = CanonicalJSON.encode_to_binary(unsigned_doc)

      assert :crypto.verify(:eddsa, :none, payload, sig_bytes, [pub_key, :ed25519])
    end

    test "the signature does NOT verify without old_verify_keys (documents the wire format it must match)",
         %{pid: pid} do
      info = GenServer.call(pid, :server_key_info)
      sig_b64 = info.signatures[info.server_name][info.key_id]

      # Same reconstruction as AxonWeb.KeyController.server_keys/2's actual
      # response, minus "old_verify_keys" — this is the document the old,
      # buggy signature was computed over. Asserting it does *not* verify
      # pins down why every real recipient's signature check used to fail:
      # canonical JSON is field-sensitive, so a signature is only valid for
      # the exact document it was computed over.
      incomplete_doc = %{
        "server_name" => info.server_name,
        "valid_until_ts" => info.valid_until_ts,
        "verify_keys" => %{info.key_id => %{"key" => info.public_key_b64}}
      }

      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)
      {:ok, sig_bytes} = Base.decode64(sig_b64, padding: false)
      payload = CanonicalJSON.encode_to_binary(incomplete_doc)

      refute :crypto.verify(:eddsa, :none, payload, sig_bytes, [pub_key, :ed25519])
    end

    test "valid_until_ts is roughly 7 days out", %{pid: pid} do
      info = GenServer.call(pid, :server_key_info)
      seven_days_ms = 7 * 24 * 60 * 60 * 1000
      now = System.os_time(:millisecond)

      assert_in_delta info.valid_until_ts, now + seven_days_ms, 5_000
    end
  end

  describe "sign/1 (via handle_call)" do
    test "produces a signature verifiable against the server's own public key", %{pid: pid} do
      payload = "arbitrary bytes to sign"
      {key_id, sig_b64} = GenServer.call(pid, {:sign, payload})

      info = GenServer.call(pid, :server_key_info)
      assert key_id == info.key_id

      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)
      {:ok, sig_bytes} = Base.decode64(sig_b64, padding: false)

      assert :crypto.verify(:eddsa, :none, payload, sig_bytes, [pub_key, :ed25519])
    end

    test "different payloads produce different signatures", %{pid: pid} do
      {_key_id, sig1} = GenServer.call(pid, {:sign, "payload one"})
      {_key_id, sig2} = GenServer.call(pid, {:sign, "payload two"})
      refute sig1 == sig2
    end
  end

  describe "sign_event/2 (via handle_call)" do
    test "signs an event map such that EventHash.verify_signature/5 accepts it", %{
      pid: pid,
      server_name: server_name
    } do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}}
      signed = GenServer.call(pid, {:sign_event, event, "11"})

      info = GenServer.call(pid, :server_key_info)
      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)

      assert :ok = EventHash.verify_signature(signed, server_name, info.key_id, pub_key, "11")
    end

    test "the signed event's non-signature fields are unchanged", %{pid: pid} do
      event = %{"type" => "m.room.message", "content" => %{"body" => "hello"}, "depth" => 3}
      signed = GenServer.call(pid, {:sign_event, event, "11"})

      assert signed["type"] == "m.room.message"
      assert signed["content"] == %{"body" => "hello"}
      assert signed["depth"] == 3
      assert Map.has_key?(signed, "signatures")
    end
  end

  describe "signing key persistence (:axon_crypto, :signing_key_path)" do
    setup do
      # A dedicated subdirectory, not the shared system tmp dir directly —
      # `persist_keypair!` chmods the key's *directory* to 0700 (see the
      # I4 fix below), and doing that to `System.tmp_dir!()` itself would
      # lock every other process on the box out of `/tmp`.
      dir =
        Path.join(System.tmp_dir!(), "axon_test_signing_key_dir_#{System.unique_integer([:positive])}")

      path = Path.join(dir, "signing_key.json")

      Application.put_env(:axon_crypto, :signing_key_path, path)

      on_exit(fn ->
        Application.delete_env(:axon_crypto, :signing_key_path)
        File.rm_rf(dir)
      end)

      %{path: path, dir: dir}
    end

    test "with no path configured, two servers still get distinct in-memory keys" do
      Application.delete_env(:axon_crypto, :signing_key_path)

      name1 = :"key_server_ephemeral_#{System.unique_integer([:positive])}"
      name2 = :"key_server_ephemeral_#{System.unique_integer([:positive])}"

      {:ok, _} =
        GenServer.start_link(KeyServer, [server_name: "ephemeral.example.org"], name: name1)

      {:ok, _} =
        GenServer.start_link(KeyServer, [server_name: "ephemeral.example.org"], name: name2)

      refute GenServer.call(name1, :server_key_info).key_id ==
               GenServer.call(name2, :server_key_info).key_id
    end

    test "generates and persists a keypair on first boot, then reloads the same one on the next",
         %{path: path} do
      name1 = :"key_server_persist_#{System.unique_integer([:positive])}"

      {:ok, _pid1} =
        GenServer.start_link(KeyServer, [server_name: "persist.example.org"], name: name1)

      info1 = GenServer.call(name1, :server_key_info)

      assert File.exists?(path)

      name2 = :"key_server_persist_#{System.unique_integer([:positive])}"

      {:ok, _pid2} =
        GenServer.start_link(KeyServer, [server_name: "persist.example.org"], name: name2)

      info2 = GenServer.call(name2, :server_key_info)

      assert info1.key_id == info2.key_id
      assert info1.public_key_b64 == info2.public_key_b64
    end

    test "the reloaded key still produces signatures verifiable against its own public key", %{
      path: path
    } do
      name1 = :"key_server_persist_sig_#{System.unique_integer([:positive])}"
      {:ok, _} = GenServer.start_link(KeyServer, [server_name: "sig.example.org"], name: name1)
      assert File.exists?(path)

      name2 = :"key_server_persist_sig_#{System.unique_integer([:positive])}"
      {:ok, _} = GenServer.start_link(KeyServer, [server_name: "sig.example.org"], name: name2)

      {_key_id, sig_b64} = GenServer.call(name2, {:sign, "reloaded key payload"})
      info = GenServer.call(name2, :server_key_info)

      {:ok, pub_key} = Base.decode64(info.public_key_b64, padding: false)
      {:ok, sig_bytes} = Base.decode64(sig_b64, padding: false)

      assert :crypto.verify(:eddsa, :none, "reloaded key payload", sig_bytes, [
               pub_key,
               :ed25519
             ])
    end

    test "the persisted file is only readable/writable by its owner", %{path: path} do
      name = :"key_server_perm_#{System.unique_integer([:positive])}"
      {:ok, _pid} = GenServer.start_link(KeyServer, [server_name: "perm.example.org"], name: name)

      mode = File.stat!(path).mode |> Bitwise.band(0o777)
      assert mode == 0o600
    end

    # Closes the window I4's file-level fix left open: a non-owner could
    # still open the temp path in the instant between its creation and its
    # own chmod, as long as the *directory* let them traverse into it at
    # all. 0700 removes that access outright rather than racing it.
    test "the key's directory is locked down to its owner", %{dir: dir} do
      name = :"key_server_dirperm_#{System.unique_integer([:positive])}"
      {:ok, _pid} = GenServer.start_link(KeyServer, [server_name: "dirperm.example.org"], name: name)

      mode = File.stat!(dir).mode |> Bitwise.band(0o777)
      assert mode == 0o700
    end

    test "leaves no temp file behind in the key's directory", %{path: path} do
      name = :"key_server_tmp_#{System.unique_integer([:positive])}"
      {:ok, _pid} = GenServer.start_link(KeyServer, [server_name: "tmp.example.org"], name: name)

      assert File.exists?(path)
      assert leftover_temp_files(path) == []
    end

    test "a stale temp file from a previous crashed write doesn't block persistence", %{
      path: path
    } do
      # The temp name carries a unique integer precisely so a leftover from
      # an interrupted boot can't collide with (or be reused by) the next
      # one — `:exclusive` would refuse to open it, and refusing to boot
      # because of debris is the wrong failure.
      stale = Path.join(Path.dirname(path), ".#{Path.basename(path)}.0.tmp")
      File.mkdir_p!(Path.dirname(path))
      File.write!(stale, "junk from a crashed write")
      on_exit(fn -> File.rm(stale) end)

      name = :"key_server_stale_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        GenServer.start_link(KeyServer, [server_name: "stale.example.org"], name: name)

      assert File.exists?(path)
      assert %{"private_key" => _} = path |> File.read!() |> Jason.decode!()
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    # The finding this covers (audit I4) is a race, so this is a *detector*
    # rather than a proof: a watcher spins on the final path for the whole
    # of the write and records every mode it ever sees. Against the previous
    # implementation — `File.write!` then `File.chmod!(0o600)` — there is a
    # window in which the file exists at whatever the umask allows (0644 on
    # a default 022 umask), and this catches it. Against the current one
    # there is no such window to catch at all: the key is written to a temp
    # file that is chmod-ed 0600 while still empty, and only then renamed
    # into place, so `path` goes from absent to 0600 in a single atomic
    # step. That's the actual guarantee; this test is what would have
    # noticed it was missing.
    test "the final path is never observable with permissions other than 0600", %{path: path} do
      parent = self()

      watcher =
        spawn_link(fn ->
          observations = watch_modes(path, System.monotonic_time(:millisecond) + 2_000, [])
          send(parent, {:observations, observations})
        end)

      name = :"key_server_race_#{System.unique_integer([:positive])}"
      {:ok, _pid} = GenServer.start_link(KeyServer, [server_name: "race.example.org"], name: name)
      assert File.exists?(path)

      send(watcher, :stop)
      assert_receive {:observations, observations}, 5_000

      assert Enum.all?(observations, &(&1 == 0o600)),
             "the key file was visible with mode(s) #{inspect(Enum.uniq(observations))}"
    end

    defp watch_modes(path, deadline, acc) do
      receive do
        :stop -> acc
      after
        0 ->
          acc =
            case File.stat(path) do
              {:ok, %{mode: mode}} -> [Bitwise.band(mode, 0o777) | acc]
              _ -> acc
            end

          if System.monotonic_time(:millisecond) >= deadline,
            do: acc,
            else: watch_modes(path, deadline, acc)
      end
    end

    defp leftover_temp_files(path) do
      dir = Path.dirname(path)
      base = Path.basename(path)

      dir
      |> File.ls!()
      |> Enum.filter(&(String.starts_with?(&1, ".#{base}.") and String.ends_with?(&1, ".tmp")))
    end
  end
end
