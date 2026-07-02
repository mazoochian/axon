defmodule AxonWeb.PushRulesController do
  use Phoenix.Controller, formats: [:json]

  # Default push rules per Matrix spec. These are the predefined server-side
  # rules that all clients expect to exist. User overrides are stored in
  # account_data but we return the defaults here for now.
  def index(conn, _params) do
    json(conn, %{"global" => default_rules()})
  end

  def get_scope(conn, %{"scope" => "global"}) do
    json(conn, %{"global" => default_rules()})
  end

  def get_scope(conn, _params) do
    conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown scope"})
  end

  def get_rule(conn, %{"scope" => "global", "kind" => kind, "rule_id" => rule_id}) do
    rules = default_rules()[kind] || []
    case Enum.find(rules, fn r -> r["rule_id"] == rule_id end) do
      nil -> conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Rule not found"})
      rule -> json(conn, rule)
    end
  end

  def get_rule(conn, _params) do
    conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown scope"})
  end

  # PUT/DELETE are accepted but we don't persist yet — return 200 for compat
  def put_rule(conn, _params), do: json(conn, %{})
  def delete_rule(conn, _params), do: json(conn, %{})
  def put_rule_enabled(conn, _params), do: json(conn, %{})
  def put_rule_actions(conn, _params), do: json(conn, %{})

  defp default_rules do
    %{
      "override" => [
        %{
          "rule_id" => ".m.rule.master",
          "default" => true,
          "enabled" => false,
          "conditions" => [],
          "actions" => ["dont_notify"]
        },
        %{
          "rule_id" => ".m.rule.suppress_notices",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "event_match", "key" => "content.msgtype", "pattern" => "m.notice"}],
          "actions" => ["dont_notify"]
        },
        %{
          "rule_id" => ".m.rule.invite_for_me",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.member"},
            %{"kind" => "event_match", "key" => "content.membership", "pattern" => "invite"},
            %{"kind" => "event_match", "key" => "state_key", "pattern" => "${user_id}"}
          ],
          "actions" => ["notify", %{"set_tweak" => "sound", "value" => "default"}, %{"set_tweak" => "highlight", "value" => false}]
        },
        %{
          "rule_id" => ".m.rule.member_event",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "event_match", "key" => "type", "pattern" => "m.room.member"}],
          "actions" => ["dont_notify"]
        },
        %{
          "rule_id" => ".m.rule.contains_display_name",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "contains_display_name"}],
          "actions" => ["notify", %{"set_tweak" => "sound", "value" => "default"}, %{"set_tweak" => "highlight"}]
        },
        %{
          "rule_id" => ".m.rule.tombstone",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.tombstone"},
            %{"kind" => "event_match", "key" => "state_key", "pattern" => ""}
          ],
          "actions" => ["notify", %{"set_tweak" => "highlight"}]
        },
        %{
          "rule_id" => ".m.rule.roomnotif",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "content.body", "pattern" => "@room"},
            %{"kind" => "sender_notification_permission", "key" => "room"}
          ],
          "actions" => ["notify", %{"set_tweak" => "highlight"}]
        }
      ],
      "content" => [
        %{
          "rule_id" => ".m.rule.contains_user_name",
          "default" => true,
          "enabled" => true,
          "pattern" => "${user_localpart}",
          "actions" => ["notify", %{"set_tweak" => "sound", "value" => "default"}, %{"set_tweak" => "highlight"}]
        }
      ],
      "room" => [],
      "sender" => [],
      "underride" => [
        %{
          "rule_id" => ".m.rule.call",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "event_match", "key" => "type", "pattern" => "m.call.invite"}],
          "actions" => ["notify", %{"set_tweak" => "sound", "value" => "ring"}, %{"set_tweak" => "highlight", "value" => false}]
        },
        %{
          "rule_id" => ".m.rule.encrypted_room_one_to_one",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "room_member_count", "is" => "==2"},
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.encrypted"}
          ],
          "actions" => ["notify", %{"set_tweak" => "sound", "value" => "default"}, %{"set_tweak" => "highlight", "value" => false}]
        },
        %{
          "rule_id" => ".m.rule.room_one_to_one",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "room_member_count", "is" => "==2"},
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.message"}
          ],
          "actions" => ["notify", %{"set_tweak" => "sound", "value" => "default"}, %{"set_tweak" => "highlight", "value" => false}]
        },
        %{
          "rule_id" => ".m.rule.message",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "event_match", "key" => "type", "pattern" => "m.room.message"}],
          "actions" => ["notify", %{"set_tweak" => "highlight", "value" => false}]
        },
        %{
          "rule_id" => ".m.rule.encrypted",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "event_match", "key" => "type", "pattern" => "m.room.encrypted"}],
          "actions" => ["notify", %{"set_tweak" => "highlight", "value" => false}]
        }
      ]
    }
  end
end
