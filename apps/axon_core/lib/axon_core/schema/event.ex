defmodule AxonCore.Schema.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "events" do
    field :event_id, :string
    field :room_id, :string
    field :sender, :string
    field :type, :string
    field :state_key, :string
    field :content, :map
    field :unsigned, :map
    field :origin_server_ts, :integer
    field :origin, :string
    field :auth_event_ids, {:array, :string}, default: []
    field :prev_event_ids, {:array, :string}, default: []
    field :depth, :integer
    field :signatures, :map, default: %{}
    field :hashes, :map, default: %{}
    field :room_version, :string
    field :rejected, :boolean, default: false
    field :soft_failed, :boolean, default: false
    field :stream_ordering, :integer

    belongs_to :room, AxonCore.Schema.Room, foreign_key: :room_id, references: :room_id, define_field: false

    timestamps(type: :utc_datetime_usec, inserted_at: :received_at, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id, :room_id, :sender, :type, :state_key, :content, :unsigned,
      :origin_server_ts, :origin, :auth_event_ids, :prev_event_ids, :depth,
      :signatures, :hashes, :room_version, :rejected, :soft_failed
    ], empty_values: [])
    |> validate_required([
      :event_id, :room_id, :sender, :type, :content,
      :origin_server_ts, :origin, :depth, :signatures, :hashes, :room_version
    ])
    |> unique_constraint(:event_id)
  end

  @doc "Converts a raw map (as received from Matrix protocol) to changeset params."
  def from_wire(event_map, room_version) do
    %{
      event_id: event_map["event_id"],
      room_id: event_map["room_id"],
      sender: event_map["sender"],
      type: event_map["type"],
      state_key: event_map["state_key"],
      content: event_map["content"] || %{},
      unsigned: event_map["unsigned"],
      origin_server_ts: event_map["origin_server_ts"],
      origin: event_map["origin"] || extract_server(event_map["sender"]),
      auth_event_ids: event_map["auth_events"] || [],
      prev_event_ids: event_map["prev_events"] || [],
      depth: event_map["depth"] || 0,
      signatures: event_map["signatures"] || %{},
      hashes: event_map["hashes"] || %{},
      room_version: room_version
    }
  end

  defp extract_server(user_id) when is_binary(user_id) do
    case String.split(user_id, ":", parts: 2) do
      [_, server] -> server
      _ -> ""
    end
  end

  defp extract_server(_), do: ""
end
