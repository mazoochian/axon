defmodule AxonCrypto.RedactionTest do
  use ExUnit.Case, async: true

  alias AxonCrypto.Redaction

  defp event(type, content, extra \\ %{}) do
    Map.merge(
      %{
        "event_id" => "$abc",
        "type" => type,
        "room_id" => "!r:localhost",
        "sender" => "@a:localhost",
        "content" => content,
        "depth" => 5,
        "prev_events" => ["$p"],
        "auth_events" => ["$a"],
        "origin_server_ts" => 1_500_000_000_000,
        "hashes" => %{"sha256" => "x"},
        "signatures" => %{"localhost" => %{"ed25519:1" => "sig"}},
        "unsigned" => %{"age" => 12}
      },
      extra
    )
  end

  test "drops unsigned and any unrecognised top-level key, keeps the protocol ones" do
    redacted = Redaction.redact(event("m.room.message", %{"body" => "hi"}, %{"junk" => 1}), "11")

    refute Map.has_key?(redacted, "unsigned")
    refute Map.has_key?(redacted, "junk")

    for key <- ~w(event_id type room_id sender content depth prev_events auth_events
                  origin_server_ts hashes signatures) do
      assert Map.has_key?(redacted, key), "expected #{key} to survive redaction"
    end
  end

  test "an ordinary message loses its whole content" do
    redacted = Redaction.redact(event("m.room.message", %{"body" => "hi", "msgtype" => "m.text"}), "11")
    assert redacted["content"] == %{}
  end

  test "m.room.member keeps only membership and the join authoriser" do
    content = %{
      "membership" => "join",
      "displayname" => "Alice",
      "avatar_url" => "mxc://x/y",
      "join_authorised_via_users_server" => "@auth:other"
    }

    assert Redaction.redact(event("m.room.member", content), "11")["content"] == %{
             "membership" => "join",
             "join_authorised_via_users_server" => "@auth:other"
           }
  end

  test "m.room.member does NOT keep third_party_invite" do
    # The spec text for recent room versions mentions preserving
    # `third_party_invite.signed`, but gomatrixserverlib — the de-facto
    # interop target, and what Complement signs with — does not implement it
    # in any of its five content keep-lists. Matching the reference here is
    # what makes signatures agree with real peers; diverging would reintroduce
    # exactly the class of self-consistent-but-incompatible bug this module
    # exists to fix. Deliberate divergence from the spec text, recorded here
    # rather than silently.
    content = %{
      "membership" => "invite",
      "third_party_invite" => %{"display_name" => "bob", "signed" => %{"token" => "t"}}
    }

    assert Redaction.redact(event("m.room.member", content), "11")["content"] == %{
             "membership" => "invite"
           }
  end

  test "join_authorised_via_users_server is protected only from v9" do
    content = %{"membership" => "join", "join_authorised_via_users_server" => "@auth:other"}

    assert Redaction.redact(event("m.room.member", content), "9")["content"] == content
    assert Redaction.redact(event("m.room.member", content), "8")["content"] == %{
             "membership" => "join"
           }
  end

  test "join_rules allow is protected only from v8" do
    content = %{"join_rule" => "restricted", "allow" => [%{"type" => "m.room_membership"}]}

    assert Redaction.redact(event("m.room.join_rules", content), "8")["content"] == content
    assert Redaction.redact(event("m.room.join_rules", content), "7")["content"] == %{
             "join_rule" => "restricted"
           }
  end

  test "power_levels invite is protected only from v11" do
    content = %{"invite" => 50, "kick" => 50}

    assert Redaction.redact(event("m.room.power_levels", content), "11")["content"] == content
    assert Redaction.redact(event("m.room.power_levels", content), "10")["content"] == %{
             "kick" => 50
           }
  end

  test "origin, prev_state and membership survive through v10, not v11" do
    extra = %{"origin" => "localhost", "prev_state" => [], "membership" => "join"}
    ev = event("m.room.member", %{"membership" => "join"}, extra)

    v10 = Redaction.redact(ev, "10")
    assert v10["origin"] == "localhost"
    assert v10["prev_state"] == []

    v11 = Redaction.redact(ev, "11")
    refute Map.has_key?(v11, "origin")
    refute Map.has_key?(v11, "prev_state")
  end

  test "content is always present, even when the event had none" do
    ev = event("m.room.message", %{}) |> Map.delete("content")
    assert Redaction.redact(ev, "11")["content"] == %{}
  end

  test "m.room.power_levels keeps its numeric rules" do
    content = %{"users" => %{"@a:x" => 100}, "kick" => 50, "notifications" => %{"room" => 20}}
    redacted = Redaction.redact(event("m.room.power_levels", content), "11")["content"]

    assert redacted["users"] == %{"@a:x" => 100}
    assert redacted["kick"] == 50
    # notifications is not in the keep-list
    refute Map.has_key?(redacted, "notifications")
  end

  test "m.room.join_rules keeps join_rule and the restricted allow list" do
    content = %{"join_rule" => "restricted", "allow" => [%{"type" => "m.room_membership"}], "x" => 1}

    assert Redaction.redact(event("m.room.join_rules", content), "11")["content"] == %{
             "join_rule" => "restricted",
             "allow" => [%{"type" => "m.room_membership"}]
           }
  end

  describe "room version differences" do
    test "m.room.create keeps all content from v11, only creator before" do
      content = %{"creator" => "@a:x", "room_version" => "11", "extra" => true}

      assert Redaction.redact(event("m.room.create", content), "11")["content"] == content
      assert Redaction.redact(event("m.room.create", content), "10")["content"] == %{"creator" => "@a:x"}
    end



    test "m.room.redaction keeps content.redacts from v11 only" do
      content = %{"redacts" => "$target", "reason" => "spam"}

      assert Redaction.redact(event("m.room.redaction", content), "11")["content"] == %{
               "redacts" => "$target"
             }

      assert Redaction.redact(event("m.room.redaction", content), "10")["content"] == %{}
    end

    test "m.room.server_acl content is fully stripped in every version" do
      # No keep-list in the reference implementation protects server ACL
      # content, in any room version — an earlier guess here that v9+ kept it
      # was wrong.
      content = %{"deny" => ["evil.com"], "allow" => ["*"]}

      for v <- ~w(6 8 9 10 11 12) do
        assert Redaction.redact(event("m.room.server_acl", content), v)["content"] == %{}
      end
    end
  end

  test "redaction is idempotent" do
    ev = event("m.room.member", %{"membership" => "join", "displayname" => "A"})
    once = Redaction.redact(ev, "11")
    assert Redaction.redact(once, "11") == once
  end
end
