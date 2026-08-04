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

  test "m.room.member keeps only the signed part of a third_party_invite" do
    content = %{
      "membership" => "invite",
      "third_party_invite" => %{"display_name" => "bob", "signed" => %{"token" => "t"}}
    }

    assert Redaction.redact(event("m.room.member", content), "11")["content"] == %{
             "membership" => "invite",
             "third_party_invite" => %{"signed" => %{"token" => "t"}}
           }
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

    test "origin/membership/prev_state survive only before v11" do
      extra = %{"origin" => "localhost", "membership" => "join", "prev_state" => []}
      ev = event("m.room.member", %{"membership" => "join"}, extra)

      old = Redaction.redact(ev, "10")
      assert old["origin"] == "localhost"
      assert old["membership"] == "join"

      new = Redaction.redact(ev, "11")
      refute Map.has_key?(new, "origin")
      refute Map.has_key?(new, "membership")
      refute Map.has_key?(new, "prev_state")
    end

    test "m.room.redaction keeps content.redacts from v11 only" do
      content = %{"redacts" => "$target", "reason" => "spam"}

      assert Redaction.redact(event("m.room.redaction", content), "11")["content"] == %{
               "redacts" => "$target"
             }

      assert Redaction.redact(event("m.room.redaction", content), "10")["content"] == %{}
    end

    test "m.room.server_acl keeps its rules from v9 onwards" do
      content = %{"deny" => ["evil.com"], "allow" => ["*"], "allow_ip_literals" => false}

      assert Redaction.redact(event("m.room.server_acl", content), "9")["content"] == content
      assert Redaction.redact(event("m.room.server_acl", content), "8")["content"] == %{}
    end
  end

  test "redaction is idempotent" do
    ev = event("m.room.member", %{"membership" => "join", "displayname" => "A"})
    once = Redaction.redact(ev, "11")
    assert Redaction.redact(once, "11") == once
  end
end
