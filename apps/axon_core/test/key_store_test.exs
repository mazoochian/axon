defmodule AxonCore.KeyStoreTest do
  @moduledoc """
  Direct tests for `AxonCore.KeyStore` against real Postgres (via
  `AxonCore.DataCase`) — device/cross-signing key retrieval, signature
  merging, and one-time-key claim atomicity/fallback.
  """

  use AxonCore.DataCase, async: false

  alias AxonCore.KeyStore

  @alice "@alice:localhost"
  @bob "@bob:localhost"

  # device_keys/cross_signing_keys/one_time_keys/fallback_keys all carry a
  # user_id foreign key into `users` — every test here needs both rows to
  # exist before it can insert against them.
  setup do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "users",
      [
        %{user_id: @alice, localpart: "alice", inserted_at: now, updated_at: now},
        %{user_id: @bob, localpart: "bob", inserted_at: now, updated_at: now}
      ],
      on_conflict: :nothing
    )

    :ok
  end

  defp insert_device_keys(user_id, device_id, keys) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "device_keys",
      [
        %{
          user_id: user_id,
          device_id: device_id,
          algorithms: ["m.olm.v1.curve25519-aes-sha2"],
          keys: keys,
          signatures: %{},
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )
  end

  defp insert_cross_signing_key(user_id, key_type, key_json) do
    Repo.insert_all(
      "cross_signing_keys",
      [%{user_id: user_id, key_type: key_type, key_json: key_json}],
      on_conflict: {:replace, [:key_json]},
      conflict_target: [:user_id, :key_type]
    )
  end

  defp insert_signature(target_user_id, target_key_id, signing_user_id, signing_key_id, sig) do
    Repo.insert_all(
      "cross_signing_signatures",
      [
        %{
          target_user_id: target_user_id,
          target_key_id: target_key_id,
          signing_user_id: signing_user_id,
          signing_key_id: signing_key_id,
          signature: sig
        }
      ],
      on_conflict: :nothing
    )
  end

  defp insert_otk(user_id, device_id, algorithm, key_id, key_json, claimed \\ false) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "one_time_keys",
      [
        %{
          user_id: user_id,
          device_id: device_id,
          algorithm: algorithm,
          key_id: key_id,
          key_json: key_json,
          claimed: claimed,
          inserted_at: now
        }
      ],
      on_conflict: :nothing
    )
  end

  defp insert_fallback_key(user_id, device_id, algorithm, key_id, key_json) do
    Repo.insert_all(
      "fallback_keys",
      [
        %{
          user_id: user_id,
          device_id: device_id,
          algorithm: algorithm,
          key_id: key_id,
          key_json: key_json,
          used: false
        }
      ],
      on_conflict: :nothing
    )
  end

  describe "device_keys_for_user/1" do
    test "returns keys keyed by device_id in the wire-format shape" do
      insert_device_keys(@alice, "DEV1", %{"ed25519:DEV1" => "pub1"})
      result = KeyStore.device_keys_for_user(@alice)

      assert %{"DEV1" => device} = result
      assert device["user_id"] == @alice
      assert device["device_id"] == "DEV1"
      assert device["keys"] == %{"ed25519:DEV1" => "pub1"}
    end

    test "returns an empty map for a user with no devices" do
      assert KeyStore.device_keys_for_user("@nobody:localhost") == %{}
    end
  end

  describe "cross_signing_keys/2" do
    test "returns key_json keyed by user_id for the requested key_type only" do
      insert_cross_signing_key(@alice, "master", %{"keys" => %{"ed25519:m" => "mval"}})
      insert_cross_signing_key(@alice, "self_signing", %{"keys" => %{"ed25519:s" => "sval"}})

      result = KeyStore.cross_signing_keys([@alice], "master")
      assert result == %{@alice => %{"keys" => %{"ed25519:m" => "mval"}}}
    end

    test "an unknown user or key_type yields no entry" do
      assert KeyStore.cross_signing_keys([@alice], "master") == %{}
    end
  end

  describe "cross_signing_signatures/2 + merge helpers" do
    test "a user's self-signature on their own key is visible to any viewer" do
      insert_signature(@alice, "ed25519:m", @alice, "ed25519:selfsign", "sigvalue")
      sigs = KeyStore.cross_signing_signatures([@alice], @bob)
      assert Map.has_key?(sigs, {@alice, "ed25519:m"})
    end

    test "a signature made by another (viewer) user on alice's key is visible only to that viewer" do
      insert_signature(@alice, "ed25519:m", @bob, "ed25519:bobkey", "sigvalue")

      assert Map.has_key?(
               KeyStore.cross_signing_signatures([@alice], @bob),
               {@alice, "ed25519:m"}
             )

      refute Map.has_key?(
               KeyStore.cross_signing_signatures([@alice], "@charlie:localhost"),
               {@alice, "ed25519:m"}
             )
    end

    test "merge_signatures/4 attaches matching rows into the key_json's signatures field" do
      insert_signature(@alice, "ed25519:m", @alice, "ed25519:selfsign", "sigvalue")
      sigs_by_target = KeyStore.cross_signing_signatures([@alice], @alice)

      key_json = %{"keys" => %{"ed25519:m" => "mval"}}
      merged = KeyStore.merge_signatures(key_json, @alice, "ed25519:m", sigs_by_target)

      assert merged["signatures"][@alice]["ed25519:selfsign"] == "sigvalue"
    end

    test "merge_signatures/4 leaves key_json untouched when there's nothing to merge" do
      key_json = %{"keys" => %{"ed25519:m" => "mval"}}
      assert KeyStore.merge_signatures(key_json, @alice, "ed25519:m", %{}) == key_json
    end

    test "merge_cross_signing_key_signatures/2 merges across every key in every user's key map" do
      insert_signature(@alice, "ed25519:m", @alice, "ed25519:selfsign", "sigA")
      sigs_by_target = KeyStore.cross_signing_signatures([@alice], @alice)

      keys_by_user = %{@alice => %{"keys" => %{"ed25519:m" => "mval"}}}
      merged = KeyStore.merge_cross_signing_key_signatures(keys_by_user, sigs_by_target)

      assert merged[@alice]["signatures"][@alice]["ed25519:selfsign"] == "sigA"
    end
  end

  describe "claim_one_time_key/3" do
    # key_id is stored as the full "algorithm:id" compound string (matching
    # apps/axon_web/lib/axon_web/controllers/key_controller.ex's upload path:
    # "key_id is 'algorithm:key_id', e.g. 'curve25519:AAAA'") and returned verbatim.
    test "claims an unclaimed OTK and marks it claimed so it can't be claimed again" do
      insert_otk(@alice, "DEV1", "curve25519", "curve25519:AAAA", %{"key" => "otkval"})

      assert %{"curve25519:AAAA" => %{"key" => "otkval"}} =
               KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")

      # Second claim finds nothing unclaimed left, falls through to fallback (none registered) -> nil.
      assert KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519") == nil
    end

    test "falls back to the (non-consumed) fallback key when no OTKs remain" do
      insert_fallback_key(@alice, "DEV1", "curve25519", "curve25519:FALLBACK1", %{
        "key" => "fallbackval",
        "fallback" => true
      })

      claim1 = KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")
      assert claim1 == %{"curve25519:FALLBACK1" => %{"key" => "fallbackval", "fallback" => true}}

      # Fallback keys are NOT consumed — claiming again returns the same key.
      claim2 = KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")
      assert claim2 == claim1
    end

    test "prefers a real OTK over the fallback key when both exist" do
      insert_otk(@alice, "DEV1", "curve25519", "curve25519:REAL1", %{"key" => "realval"})

      insert_fallback_key(@alice, "DEV1", "curve25519", "curve25519:FALLBACK1", %{
        "key" => "fallbackval"
      })

      assert %{"curve25519:REAL1" => _} =
               KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")
    end

    test "returns nil when neither an OTK nor a fallback key exists" do
      assert KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519") == nil
    end

    test "already-claimed OTKs are never returned" do
      insert_otk(@alice, "DEV1", "curve25519", "curve25519:USED1", %{"key" => "v"}, true)
      assert KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519") == nil
    end
  end

  describe "device_list_stream_id/1" do
    test "returns the max id for the user, 0 if none" do
      assert KeyStore.device_list_stream_id(@alice) == 0

      Repo.insert_all("device_list_updates", [%{user_id: @alice, stream_ordering: 5}])
      Repo.insert_all("device_list_updates", [%{user_id: @alice, stream_ordering: 10}])

      assert KeyStore.device_list_stream_id(@alice) > 0
    end
  end

  describe "device_display_names/1" do
    test "returns display names keyed by device_id" do
      now = DateTime.utc_now(:microsecond)

      Repo.insert_all(
        "users",
        [
          %{
            user_id: @alice,
            localpart: "alice",
            is_guest: false,
            deactivated: false,
            admin: false,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )

      Repo.insert_all(
        "devices",
        [
          %{
            user_id: @alice,
            device_id: "DEV1",
            display_name: "My Phone",
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )

      assert KeyStore.device_display_names(@alice) == %{"DEV1" => "My Phone"}
    end
  end

  describe "device_ids_for_user/1" do
    test "returns every device_id registered for the user" do
      insert_device(@alice, "DEV1")
      insert_device(@alice, "DEV2")
      insert_device(@bob, "OTHER")

      assert Enum.sort(KeyStore.device_ids_for_user(@alice)) == ["DEV1", "DEV2"]
    end

    test "returns an empty list for a user with no devices" do
      assert KeyStore.device_ids_for_user(@alice) == []
    end
  end

  describe "deliver_to_device/4" do
    test "stores a message per named target device" do
      insert_device(@alice, "DEV1")
      insert_device(@alice, "DEV2")

      KeyStore.deliver_to_device(@bob, @alice, "m.room_key", %{
        "DEV1" => %{"session_key" => "s1"}
      })

      rows =
        Repo.all(
          from(m in "to_device_messages",
            where: m.target_user_id == ^@alice,
            select: %{target_device_id: m.target_device_id, sender: m.sender, content: m.content}
          )
        )

      assert [%{target_device_id: "DEV1", sender: @bob, content: %{"session_key" => "s1"}}] = rows
    end

    test "expands the wildcard \"*\" target to every device the user owns" do
      insert_device(@alice, "DEV1")
      insert_device(@alice, "DEV2")

      KeyStore.deliver_to_device(@bob, @alice, "m.room_key", %{
        "*" => %{"session_key" => "everyone"}
      })

      target_devices =
        Repo.all(
          from(m in "to_device_messages",
            where: m.target_user_id == ^@alice,
            select: m.target_device_id
          )
        )

      assert Enum.sort(target_devices) == ["DEV1", "DEV2"]
    end

    test "an explicit device entry takes priority over the wildcard for the same device" do
      insert_device(@alice, "DEV1")

      KeyStore.deliver_to_device(@bob, @alice, "m.room_key", %{
        "DEV1" => %{"session_key" => "explicit"},
        "*" => %{"session_key" => "everyone"}
      })

      [row] =
        Repo.all(
          from(m in "to_device_messages",
            where: m.target_user_id == ^@alice,
            select: %{content: m.content}
          )
        )

      assert row.content == %{"session_key" => "explicit"}
    end

    test "broadcasts a wake-up for the target user" do
      Phoenix.PubSub.subscribe(Axon.PubSub, "user:#{@alice}")
      insert_device(@alice, "DEV1")

      KeyStore.deliver_to_device(@bob, @alice, "m.room_key", %{"DEV1" => %{}})

      assert_receive {:to_device, @alice}
    end
  end

  describe "purge_device/2" do
    test "removes the device row and all its associated key material" do
      now = DateTime.utc_now(:microsecond)
      insert_device(@alice, "DEV1")
      insert_device_keys(@alice, "DEV1", %{"ed25519:DEV1" => "pub1"})
      insert_otk(@alice, "DEV1", "curve25519", "curve25519:AAAA", %{"key" => "v"})
      insert_fallback_key(@alice, "DEV1", "curve25519", "curve25519:FB", %{"key" => "v"})

      Repo.insert_all("to_device_messages", [
        %{
          sender: @bob,
          target_user_id: @alice,
          target_device_id: "DEV1",
          type: "m.room_key",
          content: %{},
          inserted_at: now
        }
      ])

      KeyStore.purge_device(@alice, "DEV1")

      refute Repo.exists?(from(d in "devices", where: d.user_id == ^@alice))
      refute Repo.exists?(from(k in "device_keys", where: k.user_id == ^@alice))
      refute Repo.exists?(from(k in "one_time_keys", where: k.user_id == ^@alice))
      refute Repo.exists?(from(k in "fallback_keys", where: k.user_id == ^@alice))
      refute Repo.exists?(from(m in "to_device_messages", where: m.target_user_id == ^@alice))
    end

    test "does not touch another device's key material" do
      insert_device(@alice, "DEV1")
      insert_device(@alice, "DEV2")
      insert_device_keys(@alice, "DEV2", %{"ed25519:DEV2" => "pub2"})

      KeyStore.purge_device(@alice, "DEV1")

      assert Repo.exists?(
               from(d in "devices", where: d.user_id == ^@alice and d.device_id == "DEV2")
             )

      assert Repo.exists?(
               from(k in "device_keys", where: k.user_id == ^@alice and k.device_id == "DEV2")
             )
    end
  end

  describe "record_device_list_update/1 and record_device_list_parting/2" do
    test "record_device_list_update/1 inserts a row and wakes the user's long-poll" do
      Phoenix.PubSub.subscribe(Axon.PubSub, "user:#{@alice}")
      KeyStore.record_device_list_update(@alice)

      assert Repo.exists?(from(u in "device_list_updates", where: u.user_id == ^@alice))
      assert_receive {:device_list, @alice}
    end

    test "record_device_list_parting/2 records the parting and wakes the observer's long-poll" do
      Phoenix.PubSub.subscribe(Axon.PubSub, "user:#{@bob}")
      KeyStore.record_device_list_parting(@bob, @alice)

      assert Repo.exists?(
               from(p in "device_list_partings",
                 where: p.observer_user_id == ^@bob and p.subject_user_id == ^@alice
               )
             )

      assert_receive {:device_list, @bob}
    end
  end

  describe "device_list_partings_since/2" do
    test "returns distinct subjects parted from after the given cursor" do
      Repo.insert_all("device_list_partings", [
        %{observer_user_id: @alice, subject_user_id: @bob}
      ])

      assert KeyStore.device_list_partings_since(@alice, 0) == [@bob]
    end

    test "excludes partings at or before the cursor" do
      {1, [%{id: id}]} =
        Repo.insert_all(
          "device_list_partings",
          [%{observer_user_id: @alice, subject_user_id: @bob}],
          returning: [:id]
        )

      assert KeyStore.device_list_partings_since(@alice, id) == []
    end

    test "excludes partings observed by someone else" do
      Repo.insert_all("device_list_partings", [%{observer_user_id: @bob, subject_user_id: @alice}])

      assert KeyStore.device_list_partings_since(@alice, 0) == []
    end
  end

  defp insert_device(user_id, device_id) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "users",
      [
        %{
          user_id: user_id,
          localpart: String.trim_leading(user_id, "@") |> String.split(":") |> hd(),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    Repo.insert_all(
      "devices",
      [%{user_id: user_id, device_id: device_id, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )
  end
end
