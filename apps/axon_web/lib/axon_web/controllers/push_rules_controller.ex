defmodule AxonWeb.PushRulesController do
  use Phoenix.Controller, formats: [:json]

  alias AxonPush.DefaultRules

  def index(conn, _params) do
    json(conn, %{"global" => DefaultRules.rules()})
  end

  def get_scope(conn, %{"scope" => "global"}) do
    json(conn, %{"global" => DefaultRules.rules()})
  end

  def get_scope(conn, _params) do
    conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown scope"})
  end

  def get_rule(conn, %{"scope" => "global", "kind" => kind, "rule_id" => rule_id}) do
    rules = DefaultRules.rules()[kind] || []
    case Enum.find(rules, fn r -> r["rule_id"] == rule_id end) do
      nil -> conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Rule not found"})
      rule -> json(conn, rule)
    end
  end

  def get_rule(conn, _params) do
    conn |> put_status(404) |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Unknown scope"})
  end

  def put_rule(conn, _params), do: json(conn, %{})
  def delete_rule(conn, _params), do: json(conn, %{})
  def put_rule_enabled(conn, _params), do: json(conn, %{})
  def put_rule_actions(conn, _params), do: json(conn, %{})
end
