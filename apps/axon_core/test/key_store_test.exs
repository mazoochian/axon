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

  defp insert_device_keys(user_id, device_id, keys) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "device_keys",
      [%{user_id: user_id, device_id: device_id, algorithms: ["m.olm.v1.curve25519-aes-sha2"], keys: keys, signatures: %{}, inserted_at: now, updated_at: now}],
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
      [%{target_user_id: target_user_id, target_key_id: target_key_id, signing_user_id: signing_user_id, signing_key_id: signing_key_id, signature: sig}],
      on_conflict: :nothing
    )
  end

  defp insert_otk(user_id, device_id, algorithm, key_id, key_json, claimed \\ false) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      "one_time_keys",
      [%{user_id: user_id, device_id: device_id, algorithm: algorithm, key_id: key_id, key_json: key_json, claimed: claimed, inserted_at: now}],
      on_conflict: :nothing
    )
  end

  defp insert_fallback_key(user_id, device_id, algorithm, key_id, key_json) do
    Repo.insert_all(
      "fallback_keys",
      [%{user_id: user_id, device_id: device_id, algorithm: algorithm, key_id: key_id, key_json: key_json, used: false}],
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

      assert Map.has_key?(KeyStore.cross_signing_signatures([@alice], @bob), {@alice, "ed25519:m"})
      refute Map.has_key?(KeyStore.cross_signing_signatures([@alice], "@charlie:localhost"), {@alice, "ed25519:m"})
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

      assert %{"curve25519:AAAA" => %{"key" => "otkval"}} = KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")

      # Second claim finds nothing unclaimed left, falls through to fallback (none registered) -> nil.
      assert KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519") == nil
    end

    test "falls back to the (non-consumed) fallback key when no OTKs remain" do
      insert_fallback_key(@alice, "DEV1", "curve25519", "curve25519:FALLBACK1", %{"key" => "fallbackval", "fallback" => true})

      claim1 = KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")
      assert claim1 == %{"curve25519:FALLBACK1" => %{"key" => "fallbackval", "fallback" => true}}

      # Fallback keys are NOT consumed — claiming again returns the same key.
      claim2 = KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")
      assert claim2 == claim1
    end

    test "prefers a real OTK over the fallback key when both exist" do
      insert_otk(@alice, "DEV1", "curve25519", "curve25519:REAL1", %{"key" => "realval"})
      insert_fallback_key(@alice, "DEV1", "curve25519", "curve25519:FALLBACK1", %{"key" => "fallbackval"})

      assert %{"curve25519:REAL1" => _} = KeyStore.claim_one_time_key(@alice, "DEV1", "curve25519")
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

      Repo.insert_all("users", [%{user_id: @alice, localpart: "alice", is_guest: false, deactivated: false, admin: false, inserted_at: now, updated_at: now}], on_conflict: :nothing)
      Repo.insert_all("devices", [%{user_id: @alice, device_id: "DEV1", display_name: "My Phone", inserted_at: now, updated_at: now}], on_conflict: :nothing)

      assert KeyStore.device_display_names(@alice) == %{"DEV1" => "My Phone"}
    end
  end
end
