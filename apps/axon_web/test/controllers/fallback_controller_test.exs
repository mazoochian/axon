defmodule AxonWeb.FallbackControllerTest do
  @moduledoc """
  Direct unit tests for `AxonWeb.FallbackController.call/2`'s error->HTTP
  mapping, previously exercised only incidentally through whichever specific
  error a given controller integration test happened to trigger. Table-driven
  so every clause's status code and errcode are pinned down directly.
  """

  use AxonWeb.ConnCase, async: false

  alias AxonWeb.FallbackController

  @cases [
    {{:error, :not_found}, 404, "M_NOT_FOUND"},
    {{:error, :forbidden}, 403, "M_FORBIDDEN"},
    {{:error, :user_in_use}, 400, "M_USER_IN_USE"},
    {{:error, :invalid_input}, 400, "M_INVALID_PARAM"},
    {{:error, :not_joined}, 403, "M_FORBIDDEN"},
    {{:error, :insufficient_power}, 403, "M_FORBIDDEN"},
    {{:error, :room_already_created}, 400, "M_ROOM_IN_USE"},
    {{:error, :unsupported_room_version}, 400, "M_UNSUPPORTED_ROOM_VERSION"},
    {{:error, :banned}, 403, "M_FORBIDDEN"},
    {{:error, :not_invited}, 403, "M_FORBIDDEN"},
    {{:error, :guest_access_forbidden}, 403, "M_FORBIDDEN"},
    {{:error, :restricted_join_denied}, 403, "M_FORBIDDEN"},
    {{:error, :knocking_not_allowed}, 403, "M_FORBIDDEN"},
    {{:error, :already_in_room}, 403, "M_FORBIDDEN"},
    {{:error, :cannot_knock_for_another}, 400, "M_INVALID_PARAM"},
    {{:error, :target_banned}, 403, "M_FORBIDDEN"},
    {{:error, :target_not_in_room}, 403, "M_FORBIDDEN"},
    {{:error, :cannot_replace_default_rule}, 400, "M_INVALID_PARAM"},
    {{:error, :room_blocked}, 403, "M_FORBIDDEN"},
    {{:error, :power_levels_may_not_list_creators}, 403, "M_FORBIDDEN"},
    {{:error, :invalid_additional_creators}, 400, "M_INVALID_PARAM"},
    {{:error, {:invalid_alias_format, "#bad"}}, 400, "M_INVALID_PARAM"},
    {{:error, {:bad_canonical_alias, "#nope:localhost"}}, 400, "M_BAD_ALIAS"},
    {{:error, :some_totally_unmapped_reason}, 500, "M_UNKNOWN"}
  ]

  for {{input, status, errcode}, idx} <- Enum.with_index(@cases) do
    test "clause #{idx}: #{inspect(input)} -> #{status}/#{errcode}", %{conn: conn} do
      result = FallbackController.call(conn, unquote(Macro.escape(input)))
      assert result.status == unquote(status)
      assert Jason.decode!(result.resp_body)["errcode"] == unquote(errcode)
    end
  end

  test "the invalid_alias_format error message includes the offending alias", %{conn: conn} do
    result = FallbackController.call(conn, {:error, {:invalid_alias_format, "#bad alias"}})
    assert Jason.decode!(result.resp_body)["error"] =~ "#bad alias"
  end

  test "the bad_canonical_alias error message includes the offending alias", %{conn: conn} do
    result = FallbackController.call(conn, {:error, {:bad_canonical_alias, "#nope:localhost"}})
    assert Jason.decode!(result.resp_body)["error"] =~ "#nope:localhost"
  end

  describe "render/2 (Phoenix render_errors integration)" do
    test "404.json" do
      assert FallbackController.render("404.json", %{}) == %{
               "errcode" => "M_NOT_FOUND",
               "error" => "Not found"
             }
    end

    test "500.json" do
      assert FallbackController.render("500.json", %{}) == %{
               "errcode" => "M_UNKNOWN",
               "error" => "Internal server error"
             }
    end

    test "any other template falls back to the generic M_UNKNOWN body" do
      assert FallbackController.render("422.json", %{}) == %{
               "errcode" => "M_UNKNOWN",
               "error" => "Internal server error"
             }
    end
  end
end
