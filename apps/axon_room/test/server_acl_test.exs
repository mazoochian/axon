defmodule AxonRoom.ServerAclTest do
  use ExUnit.Case, async: true

  alias AxonRoom.ServerAcl

  describe "allowed?/2 (current_state map form)" do
    test "no m.room.server_acl event in state -> allow" do
      assert ServerAcl.allowed?(%{}, "evil.example.org")
    end

    test "reads the {\"m.room.server_acl\", \"\"} entry from current_state" do
      current_state = %{
        {"m.room.server_acl", ""} => %{
          "content" => %{"allow" => ["*"], "deny" => ["evil.example.org"]}
        }
      }

      refute ServerAcl.allowed?(current_state, "evil.example.org")
      assert ServerAcl.allowed?(current_state, "good.example.org")
    end
  end

  describe "allowed_by_content?/2" do
    test "deny takes precedence over allow when both match" do
      content = %{"allow" => ["*"], "deny" => ["evil.example.org"]}
      refute ServerAcl.allowed_by_content?(content, "evil.example.org")
      assert ServerAcl.allowed_by_content?(content, "fine.example.org")
    end

    test "glob wildcard in deny blocks a whole domain suffix" do
      content = %{"allow" => ["*"], "deny" => ["*.evil.com", "evil.com"]}
      refute ServerAcl.allowed_by_content?(content, "evil.com")
      refute ServerAcl.allowed_by_content?(content, "sub.evil.com")
      assert ServerAcl.allowed_by_content?(content, "notevil.com")
    end

    test "matching is case-insensitive" do
      content = %{"allow" => ["*"], "deny" => ["EVIL.example.org"]}
      refute ServerAcl.allowed_by_content?(content, "evil.example.org")
    end

    test "not matching allow (and no deny match) falls through to deny by default" do
      content = %{"allow" => ["good.example.org"]}
      refute ServerAcl.allowed_by_content?(content, "elsewhere.example.org")
      assert ServerAcl.allowed_by_content?(content, "good.example.org")
    end

    test "missing/empty allow list denies everyone (spec: defaults to empty list)" do
      content = %{"deny" => ["evil.example.org"]}
      refute ServerAcl.allowed_by_content?(content, "anyone.example.org")
    end

    test "port is stripped before matching either side" do
      content = %{"allow" => ["*"], "deny" => ["evil.com"]}
      refute ServerAcl.allowed_by_content?(content, "evil.com:8448")
      refute ServerAcl.allowed_by_content?(content, "evil.com:1234")
    end

    test "allow_ip_literals: false denies an IPv4 literal even if it matches allow" do
      content = %{"allow" => ["*"], "allow_ip_literals" => false}
      refute ServerAcl.allowed_by_content?(content, "1.2.3.4")
      assert ServerAcl.allowed_by_content?(content, "example.org")
    end

    test "allow_ip_literals defaults to true (missing or non-boolean)" do
      content = %{"allow" => ["*"]}
      assert ServerAcl.allowed_by_content?(content, "1.2.3.4")

      content2 = %{"allow" => ["*"], "allow_ip_literals" => "false"}
      assert ServerAcl.allowed_by_content?(content2, "1.2.3.4")
    end

    test "allow_ip_literals: false denies a bracketed IPv6 literal too, with or without a port" do
      content = %{"allow" => ["*"], "allow_ip_literals" => false}
      refute ServerAcl.allowed_by_content?(content, "[::1]")
      refute ServerAcl.allowed_by_content?(content, "[::1]:8448")
    end

    test "? glob matches exactly one character" do
      content = %{"allow" => ["ho?t.example.org"]}
      assert ServerAcl.allowed_by_content?(content, "host.example.org")
      refute ServerAcl.allowed_by_content?(content, "hoost.example.org")
    end
  end
end
