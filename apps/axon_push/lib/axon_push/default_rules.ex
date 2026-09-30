defmodule AxonPush.DefaultRules do
  @moduledoc "Matrix default push ruleset. Kept here so axon_push doesn't depend on axon_web."

  @kinds ~w(override content room sender underride)

  @doc "The push rule kinds, in evaluation priority order."
  def kinds, do: @kinds

  @doc """
  The default ruleset as served to `user_id` (`.m.rule.is_user_mention`
  carries the user's own ID). Without a user, that value is the
  `${user_id}` placeholder.
  """
  def rules(user_id \\ "${user_id}") do
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
          "conditions" => [
            %{"kind" => "event_match", "key" => "content.msgtype", "pattern" => "m.notice"}
          ],
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
          "actions" => [
            "notify",
            %{"set_tweak" => "sound", "value" => "default"},
            %{"set_tweak" => "highlight", "value" => false}
          ]
        },
        %{
          "rule_id" => ".m.rule.member_event",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.member"}
          ],
          "actions" => ["dont_notify"]
        },
        %{
          "rule_id" => ".m.rule.is_user_mention",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{
              "kind" => "event_property_contains",
              "key" => "content.m\\.mentions.user_ids",
              "value" => user_id
            }
          ],
          "actions" => [
            "notify",
            %{"set_tweak" => "sound", "value" => "default"},
            %{"set_tweak" => "highlight"}
          ]
        },
        %{
          "rule_id" => ".m.rule.contains_display_name",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "contains_display_name"}],
          "actions" => [
            "notify",
            %{"set_tweak" => "sound", "value" => "default"},
            %{"set_tweak" => "highlight"}
          ]
        },
        %{
          "rule_id" => ".m.rule.is_room_mention",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{
              "kind" => "event_property_is",
              "key" => "content.m\\.mentions.room",
              "value" => true
            },
            %{"kind" => "sender_notification_permission", "key" => "room"}
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
          "rule_id" => ".m.rule.reaction",
          "default" => true,
          "enabled" => true,
          "conditions" => [%{"kind" => "event_match", "key" => "type", "pattern" => "m.reaction"}],
          "actions" => []
        },
        %{
          "rule_id" => ".m.rule.room.server_acl",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.server_acl"},
            %{"kind" => "event_match", "key" => "state_key", "pattern" => ""}
          ],
          "actions" => []
        },
        %{
          "rule_id" => ".m.rule.suppress_edits",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{
              "kind" => "event_property_is",
              "key" => "content.m\\.relates_to.rel_type",
              "value" => "m.replace"
            }
          ],
          "actions" => []
        }
      ],
      "content" => [
        %{
          "rule_id" => ".m.rule.contains_user_name",
          "default" => true,
          "enabled" => true,
          "pattern" => "${user_localpart}",
          "actions" => [
            "notify",
            %{"set_tweak" => "sound", "value" => "default"},
            %{"set_tweak" => "highlight"}
          ]
        }
      ],
      "room" => [],
      "sender" => [],
      "underride" => [
        %{
          "rule_id" => ".m.rule.call",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.call.invite"}
          ],
          "actions" => [
            "notify",
            %{"set_tweak" => "sound", "value" => "ring"},
            %{"set_tweak" => "highlight", "value" => false}
          ]
        },
        %{
          "rule_id" => ".m.rule.encrypted_room_one_to_one",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "room_member_count", "is" => "==2"},
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.encrypted"}
          ],
          "actions" => [
            "notify",
            %{"set_tweak" => "sound", "value" => "default"},
            %{"set_tweak" => "highlight", "value" => false}
          ]
        },
        %{
          "rule_id" => ".m.rule.room_one_to_one",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "room_member_count", "is" => "==2"},
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.message"}
          ],
          "actions" => [
            "notify",
            %{"set_tweak" => "sound", "value" => "default"},
            %{"set_tweak" => "highlight", "value" => false}
          ]
        },
        %{
          "rule_id" => ".m.rule.message",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.message"}
          ],
          "actions" => ["notify", %{"set_tweak" => "highlight", "value" => false}]
        },
        %{
          "rule_id" => ".m.rule.encrypted",
          "default" => true,
          "enabled" => true,
          "conditions" => [
            %{"kind" => "event_match", "key" => "type", "pattern" => "m.room.encrypted"}
          ],
          "actions" => ["notify", %{"set_tweak" => "highlight", "value" => false}]
        }
      ]
    }
  end
end
