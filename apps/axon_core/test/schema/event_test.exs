defmodule AxonCore.Schema.EventTest do
  @moduledoc """
  Direct unit tests for `AxonCore.Schema.Event.from_wire/2`'s field mapping
  and, specifically, its `origin` fallback (derive from `sender`'s domain
  when the wire map omits `origin` outright) — untested at the unit level
  before now, only ever exercised incidentally via events that already had
  a real `origin` set.
  """

  use ExUnit.Case, async: true

  alias AxonCore.Schema.Event

  describe "from_wire/2 origin fallback" do
    test "uses the wire map's own origin when present" do
      params = Event.from_wire(%{"sender" => "@alice:elsewhere.example", "origin" => "explicit.example"}, "10")
      assert params.origin == "explicit.example"
    end

    test "derives origin from the sender's domain when origin is absent" do
      params = Event.from_wire(%{"sender" => "@alice:derived.example"}, "10")
      assert params.origin == "derived.example"
    end

    test "falls back to an empty string when sender has no domain part" do
      params = Event.from_wire(%{"sender" => "not-a-real-mxid"}, "10")
      assert params.origin == ""
    end

    test "falls back to an empty string when sender is nil" do
      params = Event.from_wire(%{}, "10")
      assert params.origin == ""
    end
  end

  describe "from_wire/2 field mapping and defaults" do
    test "maps every wire field to its changeset key" do
      wire = %{
        "event_id" => "$abc",
        "room_id" => "!room:localhost",
        "sender" => "@alice:localhost",
        "type" => "m.room.message",
        "state_key" => "",
        "content" => %{"body" => "hi"},
        "unsigned" => %{"age" => 5},
        "origin_server_ts" => 1000,
        "origin" => "localhost",
        "auth_events" => ["$a"],
        "prev_events" => ["$b"],
        "depth" => 3,
        "signatures" => %{"localhost" => %{"ed25519:1" => "sig"}},
        "hashes" => %{"sha256" => "h"}
      }

      params = Event.from_wire(wire, "11")

      assert params.event_id == "$abc"
      assert params.room_id == "!room:localhost"
      assert params.sender == "@alice:localhost"
      assert params.type == "m.room.message"
      assert params.state_key == ""
      assert params.content == %{"body" => "hi"}
      assert params.unsigned == %{"age" => 5}
      assert params.origin_server_ts == 1000
      assert params.auth_event_ids == ["$a"]
      assert params.prev_event_ids == ["$b"]
      assert params.depth == 3
      assert params.signatures == wire["signatures"]
      assert params.hashes == wire["hashes"]
      assert params.room_version == "11"
    end

    test "defaults content/auth_events/prev_events/depth/signatures/hashes when absent" do
      params = Event.from_wire(%{}, "11")

      assert params.content == %{}
      assert params.auth_event_ids == []
      assert params.prev_event_ids == []
      assert params.depth == 0
      assert params.signatures == %{}
      assert params.hashes == %{}
    end
  end

  describe "changeset/2" do
    test "is valid with all required fields present" do
      attrs = %{
        event_id: "$abc",
        room_id: "!room:localhost",
        sender: "@alice:localhost",
        type: "m.room.message",
        content: %{},
        origin_server_ts: 1000,
        origin: "localhost",
        depth: 1,
        signatures: %{},
        hashes: %{},
        room_version: "10"
      }

      changeset = Event.changeset(%Event{}, attrs)
      assert changeset.valid?
    end

    test "is invalid when a required field is missing" do
      changeset = Event.changeset(%Event{}, %{event_id: "$abc"})
      refute changeset.valid?
      assert %{room_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
