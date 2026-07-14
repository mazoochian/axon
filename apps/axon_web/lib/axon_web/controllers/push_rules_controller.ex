defmodule AxonWeb.PushRulesController do
  @moduledoc """
  Push rules (`/pushrules/...`). `PUT`/`DELETE` used to silently discard —
  only the server default rule set was ever actually served, regardless of
  what a client tried to customize. Now backed by `AxonPush.UserRules`.

  Only the `global` scope is supported (matches every other homeserver in
  practice — the spec's `device` scope has no real client usage).
  """

  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  alias AxonPush.UserRules

  def index(conn, _params) do
    json(conn, %{"global" => UserRules.effective_rules(conn.assigns.current_user_id)})
  end

  def get_scope(conn, %{"scope" => "global"}) do
    json(conn, %{"global" => UserRules.effective_rules(conn.assigns.current_user_id)})
  end

  def get_scope(conn, _params) do
    conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown scope"})
  end

  def get_rule(conn, %{"scope" => "global", "kind" => kind, "rule_id" => rule_id}) do
    case UserRules.get_rule(conn.assigns.current_user_id, kind, rule_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Rule not found"})

      rule ->
        json(conn, rule)
    end
  end

  def get_rule(conn, _params) do
    conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown scope"})
  end

  def put_rule(conn, %{"scope" => "global", "kind" => kind, "rule_id" => rule_id} = params) do
    with :ok <- UserRules.put_custom_rule(conn.assigns.current_user_id, kind, rule_id, params) do
      json(conn, %{})
    end
  end

  def delete_rule(conn, %{"scope" => "global", "kind" => kind, "rule_id" => rule_id}) do
    :ok = UserRules.delete_rule(conn.assigns.current_user_id, kind, rule_id)
    json(conn, %{})
  end

  def put_rule_enabled(conn, %{
        "scope" => "global",
        "kind" => kind,
        "rule_id" => rule_id,
        "enabled" => enabled
      }) do
    with :ok <- UserRules.put_enabled(conn.assigns.current_user_id, kind, rule_id, enabled) do
      json(conn, %{})
    end
  end

  def put_rule_enabled(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "enabled is required"})
  end

  def put_rule_actions(conn, %{
        "scope" => "global",
        "kind" => kind,
        "rule_id" => rule_id,
        "actions" => actions
      }) do
    with :ok <- UserRules.put_actions(conn.assigns.current_user_id, kind, rule_id, actions) do
      json(conn, %{})
    end
  end

  def put_rule_actions(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "actions is required"})
  end
end
