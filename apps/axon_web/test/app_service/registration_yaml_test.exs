defmodule AxonWeb.AppService.RegistrationYamlTest do
  @moduledoc """
  Unit tests for the narrow YAML reader that parses Complement's
  generated application service registration files (see the module's own
  moduledoc for exactly which fixed shape it supports and why it isn't a
  general YAML parser).
  """

  use ExUnit.Case, async: true

  alias AxonWeb.AppService.RegistrationYaml

  # Exactly what Complement's generateASRegistrationYaml (internal/docker/builder.go)
  # emits — a real byte-for-byte fixture, not a hand-simplified approximation.
  @complement_fixture """
  id: my_as_id
  hs_token: hs-secret-abc
  as_token: as-secret-xyz
  url: 'http://localhost:9000'
  sender_localpart: the-bridge-user
  rate_limited: false
  de.sorunome.msc2409.push_ephemeral: false
  push_ephemeral: false
  org.matrix.msc3202: false
  namespaces:
    users:
      - exclusive: false
        regex: .*
    rooms: []
    aliases: []
  """

  test "parses every scalar field from Complement's exact generated format" do
    assert {:ok, reg} = RegistrationYaml.parse(@complement_fixture)

    assert reg["id"] == "my_as_id"
    assert reg["hs_token"] == "hs-secret-abc"
    assert reg["as_token"] == "as-secret-xyz"
    assert reg["sender_localpart"] == "the-bridge-user"
  end

  test "strips single-quote wrapping from the url field" do
    assert {:ok, reg} = RegistrationYaml.parse(@complement_fixture)
    assert reg["url"] == "http://localhost:9000"
  end

  test "parses boolean literals as real booleans, not strings" do
    assert {:ok, reg} = RegistrationYaml.parse(@complement_fixture)
    assert reg["rate_limited"] == false
    assert reg["push_ephemeral"] == false
  end

  test "produces the same namespaces shape the JSON loader produces" do
    assert {:ok, reg} = RegistrationYaml.parse(@complement_fixture)

    assert reg["namespaces"] == %{
             "users" => [%{"exclusive" => false, "regex" => ".*"}],
             "rooms" => [],
             "aliases" => []
           }
  end

  test "a narrower user namespace regex round-trips correctly" do
    yaml = """
    id: bridge2
    hs_token: h
    as_token: a
    url: 'http://x'
    sender_localpart: bridge2
    rate_limited: true
    de.sorunome.msc2409.push_ephemeral: true
    push_ephemeral: true
    org.matrix.msc3202: true
    namespaces:
      users:
        - exclusive: true
          regex: @bridge2_.*
      rooms: []
      aliases: []
    """

    assert {:ok, reg} = RegistrationYaml.parse(yaml)

    assert reg["namespaces"]["users"] == [
             %{"exclusive" => true, "regex" => "@bridge2_.*"}
           ]
  end
end
