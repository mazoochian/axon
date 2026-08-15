defmodule AxonWeb.KeysClaimTest do
  @moduledoc """
  `POST /_matrix/client/v3/keys/claim` — a user with nothing actually
  claimed (no key uploaded, or already exhausted) must be absent from the
  response entirely, not present with an empty device map. Found via
  Complement's TestFederationKeyUploadQuery, which checks the former with
  `JSONKeyMissing`.
  """

  use AxonWeb.ConnCase, async: false

  import AxonWeb.TestHelpers
  alias AxonCore.Repo

  test "claiming an uploaded key returns it once, then omits the user once exhausted" do
    alice = register("claim_#{System.unique_integer([:positive])}")
    key_json = %{"key" => "fake_curve25519_key_value"}

    Repo.insert_all("one_time_keys", [
      %{
        user_id: alice.user_id,
        device_id: alice.device_id,
        algorithm: "curve25519",
        key_id: "curve25519:AAAAAA",
        key_json: key_json,
        claimed: false,
        inserted_at: DateTime.utc_now(:microsecond)
      }
    ])

    request = %{
      "one_time_keys" => %{alice.user_id => %{alice.device_id => "curve25519"}}
    }

    conn1 = authed(alice.token) |> jp("/_matrix/client/v3/keys/claim", request)
    body1 = decode(conn1)
    assert body1["one_time_keys"][alice.user_id][alice.device_id] == %{"curve25519:AAAAAA" => key_json}

    conn2 = authed(alice.token) |> jp("/_matrix/client/v3/keys/claim", request)
    refute Map.has_key?(decode(conn2)["one_time_keys"], alice.user_id)
  end

  test "claiming for a user/device with no uploaded key returns an empty result, no bare entry" do
    alice = register("claim_empty_#{System.unique_integer([:positive])}")

    conn =
      authed(alice.token)
      |> jp("/_matrix/client/v3/keys/claim", %{
        "one_time_keys" => %{alice.user_id => %{alice.device_id => "curve25519"}}
      })

    assert decode(conn)["one_time_keys"] == %{}
  end
end
