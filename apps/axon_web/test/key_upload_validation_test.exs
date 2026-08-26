defmodule AxonWeb.KeyUploadValidationTest do
  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers
  import Ecto.Query

  alias AxonCore.Repo

  test "rejects device_keys missing a required field without storing any keys" do
    required_fields = ["user_id", "device_id", "algorithms", "keys", "signatures"]

    for missing_field <- required_fields do
      device =
        register("key_upload_missing_#{missing_field}_#{System.unique_integer([:positive])}")

      conn =
        authed(device.token)
        |> jp(
          "/_matrix/client/v3/keys/upload",
          upload_body(device, Map.delete(valid_device_keys(device), missing_field))
        )

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_BAD_JSON"
      assert key_row_counts(device) == {0, 0, 0}
    end
  end

  test "rejects device_keys whose embedded identity differs from the authenticated device" do
    for mismatched_field <- ["user_id", "device_id"] do
      device =
        register("key_upload_identity_#{mismatched_field}_#{System.unique_integer([:positive])}")

      device_keys = Map.put(valid_device_keys(device), mismatched_field, "different")

      conn =
        authed(device.token)
        |> jp("/_matrix/client/v3/keys/upload", upload_body(device, device_keys))

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_BAD_JSON"
      assert key_row_counts(device) == {0, 0, 0}
    end
  end

  test "rejects device_keys unless algorithms is a list of strings" do
    for invalid_algorithms <- ["m.olm.v1.curve25519-aes-sha2", ["valid", 42]] do
      device = register("key_upload_algorithms_#{System.unique_integer([:positive])}")
      device_keys = Map.put(valid_device_keys(device), "algorithms", invalid_algorithms)

      conn =
        authed(device.token)
        |> jp("/_matrix/client/v3/keys/upload", upload_body(device, device_keys))

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_BAD_JSON"
      assert key_row_counts(device) == {0, 0, 0}
    end
  end

  test "rejects device_keys unless keys and signatures are objects" do
    for field <- ["keys", "signatures"] do
      device = register("key_upload_object_#{field}_#{System.unique_integer([:positive])}")
      device_keys = Map.put(valid_device_keys(device), field, ["not", "an", "object"])

      conn =
        authed(device.token)
        |> jp("/_matrix/client/v3/keys/upload", upload_body(device, device_keys))

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_BAD_JSON"
      assert key_row_counts(device) == {0, 0, 0}
    end
  end

  test "rejects device_keys whose keys object contains a non-string value without storing any keys" do
    device = register("key_upload_key_value_#{System.unique_integer([:positive])}")

    device_keys =
      Map.put(valid_device_keys(device), "keys", %{
        "ed25519:#{device.device_id}" => %{"key" => "not-a-string"}
      })

    conn =
      authed(device.token)
      |> jp("/_matrix/client/v3/keys/upload", upload_body(device, device_keys))

    assert conn.status == 400
    assert decode(conn)["errcode"] == "M_BAD_JSON"
    assert key_row_counts(device) == {0, 0, 0}
  end

  test "rejects signatures unless signer entries are maps of string values without storing any keys" do
    invalid_signatures = [
      %{"@signer:example.test" => "not-a-map"},
      %{"@signer:example.test" => %{"ed25519:signing-key" => %{"signature" => "not-a-string"}}}
    ]

    for signatures <- invalid_signatures do
      device = register("key_upload_signature_shape_#{System.unique_integer([:positive])}")
      device_keys = Map.put(valid_device_keys(device), "signatures", signatures)

      conn =
        authed(device.token)
        |> jp("/_matrix/client/v3/keys/upload", upload_body(device, device_keys))

      assert conn.status == 400
      assert decode(conn)["errcode"] == "M_BAD_JSON"
      assert key_row_counts(device) == {0, 0, 0}
    end
  end

  defp valid_device_keys(device) do
    %{
      "user_id" => device.user_id,
      "device_id" => device.device_id,
      "algorithms" => ["m.olm.v1.curve25519-aes-sha2"],
      "keys" => %{"ed25519:#{device.device_id}" => "device-key"},
      "signatures" => %{}
    }
  end

  defp upload_body(_device, device_keys) do
    %{
      "device_keys" => device_keys,
      "one_time_keys" => %{"signed_curve25519:OTK" => %{"key" => "otk"}},
      "fallback_keys" => %{"signed_curve25519:FALLBACK" => %{"key" => "fallback"}}
    }
  end

  defp key_row_counts(device) do
    counts = fn table ->
      Repo.aggregate(
        from(k in table,
          where: k.user_id == ^device.user_id and k.device_id == ^device.device_id
        ),
        :count
      )
    end

    {counts.("device_keys"), counts.("one_time_keys"), counts.("fallback_keys")}
  end
end
