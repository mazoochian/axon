defmodule AxonWeb.AppService.RegistrationLoadingTest do
  @moduledoc """
  Regression coverage for `AxonWeb.AppService.Manager`'s file-based
  registration loading: `:axon_web, :appservice_registration_files` is a
  list of single-registration JSON file paths (Synapse-style — one file
  per bridge — rather than Phase 4's original single-array-file shape).
  Malformed/invalid files and id/token collisions are dropped with a
  warning rather than crashing boot.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AxonWeb.AppService.Manager

  @table :axon_appservices
  @tmp_dir Path.join(System.tmp_dir!(), "axon_as_registration_loading_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    original = Application.get_env(:axon_web, :appservice_registration_files, [])

    on_exit(fn ->
      Application.put_env(:axon_web, :appservice_registration_files, original)
      Manager.reload()
      :ets.insert(@table, {:registrations, []})
      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  defp write_file(name, content) do
    path = Path.join(@tmp_dir, name)
    File.write!(path, content)
    path
  end

  defp valid_registration(id) do
    Jason.encode!(%{
      "id" => id,
      "url" => "http://localhost:9000",
      "as_token" => "as-#{id}",
      "hs_token" => "hs-#{id}",
      "sender_localpart" => "_#{id}",
      "namespaces" => %{
        "users" => [%{"exclusive" => true, "regex" => "@#{id}_.*"}],
        "aliases" => [],
        "rooms" => []
      }
    })
  end

  defp reload_with(paths) do
    Application.put_env(:axon_web, :appservice_registration_files, paths)
    Manager.reload()
  end

  test "loads a valid registration from a single file" do
    path = write_file("bridge1.json", valid_registration("bridge1"))
    regs = reload_with([path])

    assert length(regs) == 1
    assert Manager.verify_as_token("as-bridge1") == {:ok, hd(regs)}
  end

  test "loads multiple registrations, one per file" do
    path1 = write_file("bridge_a.json", valid_registration("bridge_a"))
    path2 = write_file("bridge_b.json", valid_registration("bridge_b"))

    regs = reload_with([path1, path2])

    assert length(regs) == 2
    assert Manager.find_by_id("bridge_a") != :error
    assert Manager.find_by_id("bridge_b") != :error
  end

  test "a missing file is skipped with a warning, not a crash" do
    log =
      capture_log(fn ->
        regs = reload_with([Path.join(@tmp_dir, "does_not_exist.json")])
        assert regs == []
      end)

    assert log =~ "not found"
  end

  test "invalid JSON is skipped with a warning" do
    path = write_file("broken.json", "{not valid json")

    log =
      capture_log(fn ->
        regs = reload_with([path])
        assert regs == []
      end)

    assert log =~ "not valid JSON"
  end

  test "a registration missing a required field is skipped" do
    path = write_file("missing_field.json", Jason.encode!(%{"id" => "x", "url" => "http://x"}))

    log =
      capture_log(fn ->
        regs = reload_with([path])
        assert regs == []
      end)

    assert log =~ "missing required field"
  end

  test "a registration with an unparseable namespace regex is skipped" do
    bad =
      Jason.encode!(%{
        "id" => "badregex",
        "url" => "http://localhost:9000",
        "as_token" => "as-badregex",
        "hs_token" => "hs-badregex",
        "sender_localpart" => "_badregex",
        "namespaces" => %{
          "users" => [%{"exclusive" => true, "regex" => "("}],
          "aliases" => [],
          "rooms" => []
        }
      })

    path = write_file("badregex.json", bad)

    log =
      capture_log(fn ->
        regs = reload_with([path])
        assert regs == []
      end)

    assert log =~ "invalid"
  end

  test "a duplicate as_token across files is dropped, first file wins" do
    reg = Jason.decode!(valid_registration("dup"))
    path1 = write_file("dup1.json", Jason.encode!(reg))
    path2 = write_file("dup2.json", Jason.encode!(Map.put(reg, "id", "dup_other")))

    log =
      capture_log(fn ->
        regs = reload_with([path1, path2])
        assert length(regs) == 1
        assert hd(regs)["id"] == "dup"
      end)

    assert log =~ "duplicate"
  end

  test "reload/0 replaces the previous registration set entirely" do
    path1 = write_file("first.json", valid_registration("first"))
    reload_with([path1])
    assert Manager.find_by_id("first") != :error

    path2 = write_file("second.json", valid_registration("second"))
    reload_with([path2])

    assert Manager.find_by_id("first") == :error
    assert Manager.find_by_id("second") != :error
  end
end
