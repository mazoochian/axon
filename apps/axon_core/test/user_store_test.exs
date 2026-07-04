defmodule AxonCore.UserStoreTest do
  @moduledoc """
  Direct tests for `AxonCore.UserStore` against real Postgres (via
  `AxonCore.DataCase`) — registration, login, token lifecycle, and OIDC
  auto-provisioning edge cases.
  """

  use AxonCore.DataCase, async: false

  alias AxonCore.UserStore

  defp uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  describe "register/3" do
    test "returns a valid user_id/access_token/device_id" do
      localpart = uniq("alice")
      assert {:ok, result} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
      assert result.user_id == "@#{localpart}:localhost"
      assert is_binary(result.access_token)
      assert is_binary(result.device_id)
    end

    test "a duplicate localpart is rejected" do
      localpart = uniq("alice")
      assert {:ok, _} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
      assert UserStore.register(localpart, "Different1!", server_name: "localhost") == {:error, :user_in_use}
    end

    test "a guest registration sets is_guest and needs no password" do
      localpart = uniq("guest")
      assert {:ok, result} = UserStore.register(localpart, nil, server_name: "localhost", is_guest: true)
      assert UserStore.guest?(result.user_id) == true
    end

    test "a normal registration is not a guest" do
      localpart = uniq("alice")
      {:ok, result} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
      assert UserStore.guest?(result.user_id) == false
    end

    test "an explicit device_id is honored instead of a generated one" do
      localpart = uniq("alice")
      {:ok, result} = UserStore.register(localpart, "Test1234!", server_name: "localhost", device_id: "MYDEVICE")
      assert result.device_id == "MYDEVICE"
    end
  end

  describe "login/3" do
    setup do
      localpart = uniq("alice")
      {:ok, reg} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
      %{localpart: localpart, user_id: reg.user_id}
    end

    test "correct password succeeds and issues a token", %{localpart: localpart, user_id: user_id} do
      assert {:ok, result} = UserStore.login(localpart, "Test1234!", server_name: "localhost")
      assert result.user_id == user_id
      assert is_binary(result.access_token)
    end

    test "wrong password is forbidden", %{localpart: localpart} do
      assert UserStore.login(localpart, "WrongPassword!", server_name: "localhost") == {:error, :forbidden}
    end

    test "an unknown user is forbidden" do
      assert UserStore.login(uniq("nobody"), "whatever", server_name: "localhost") == {:error, :forbidden}
    end

    test "a deactivated user cannot log in", %{localpart: localpart, user_id: user_id} do
      import Ecto.Query
      Repo.update_all(from(u in "users", where: u.user_id == ^user_id), set: [deactivated: true])
      assert UserStore.login(localpart, "Test1234!", server_name: "localhost") == {:error, :forbidden}
    end

    test "login by full user_id (not just localpart) works", %{user_id: user_id} do
      assert {:ok, _} = UserStore.login(user_id, "Test1234!", server_name: "localhost")
    end
  end

  describe "token lifecycle" do
    setup do
      localpart = uniq("alice")
      {:ok, reg} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
      %{reg: reg}
    end

    test "validate_token resolves a fresh token to {user_id, device_id}", %{reg: reg} do
      assert UserStore.validate_token(reg.access_token) == {:ok, {reg.user_id, reg.device_id}}
    end

    test "validate_token rejects an unknown token" do
      assert UserStore.validate_token("not-a-real-token") == :error
    end

    test "logout invalidates the token", %{reg: reg} do
      assert UserStore.validate_token(reg.access_token) == {:ok, {reg.user_id, reg.device_id}}
      :ok = UserStore.logout(reg.access_token)
      assert UserStore.validate_token(reg.access_token) == :error
    end

    test "logout_all invalidates every token except the one excluded", %{reg: reg} do
      {:ok, reg2} = UserStore.login(reg.user_id, "Test1234!", server_name: "localhost")

      :ok = UserStore.logout_all(reg.user_id, reg2.access_token)

      assert UserStore.validate_token(reg.access_token) == :error
      assert UserStore.validate_token(reg2.access_token) == {:ok, {reg.user_id, reg2.device_id}}
    end
  end

  describe "authenticate_via_oidc/4" do
    test "provisions a new local user on first use" do
      subject = uniq("subject")
      localpart = uniq("oidcuser")

      assert {:ok, {user_id, "DEV1"}} =
               UserStore.authenticate_via_oidc(subject, localpart, "DEV1", "localhost")

      assert user_id == "@#{localpart}:localhost"
    end

    test "reuses the same local user for the same subject on subsequent calls" do
      subject = uniq("subject")
      localpart = uniq("oidcuser")

      {:ok, {user_id1, _}} = UserStore.authenticate_via_oidc(subject, localpart, "DEV1", "localhost")
      {:ok, {user_id2, _}} = UserStore.authenticate_via_oidc(subject, "irrelevant_localpart_now", "DEV2", "localhost")

      assert user_id1 == user_id2
    end

    test "refuses to attach an OIDC subject to an existing local password account with the same localpart" do
      localpart = uniq("alice")
      {:ok, _} = UserStore.register(localpart, "Test1234!", server_name: "localhost")

      assert UserStore.authenticate_via_oidc(uniq("subject"), localpart, "DEV1", "localhost") ==
               {:error, :localpart_taken_by_local_account}
    end

    test "refuses to attach a different OIDC subject to an already-oidc-linked localpart" do
      localpart = uniq("oidcuser")
      {:ok, _} = UserStore.authenticate_via_oidc(uniq("subject_a"), localpart, "DEV1", "localhost")

      assert UserStore.authenticate_via_oidc(uniq("subject_b"), localpart, "DEV2", "localhost") ==
               {:error, :localpart_taken_by_other_subject}
    end

    test "a deactivated OIDC-provisioned user is refused on subsequent auth" do
      import Ecto.Query
      subject = uniq("subject")
      localpart = uniq("oidcuser")

      {:ok, {user_id, _}} = UserStore.authenticate_via_oidc(subject, localpart, "DEV1", "localhost")
      Repo.update_all(from(u in "users", where: u.user_id == ^user_id), set: [deactivated: true])

      assert UserStore.authenticate_via_oidc(subject, localpart, "DEV2", "localhost") == {:error, :deactivated}
    end
  end

  describe "profile" do
    test "get_profile/update_profile round-trip" do
      localpart = uniq("alice")
      {:ok, reg} = UserStore.register(localpart, "Test1234!", server_name: "localhost")

      assert {:ok, profile} = UserStore.get_profile(reg.user_id)
      assert profile.displayname == localpart

      assert {:ok, _} = UserStore.update_profile(reg.user_id, %{displayname: "New Name"})
      assert {:ok, updated} = UserStore.get_profile(reg.user_id)
      assert updated.displayname == "New Name"
    end

    test "get_profile for an unknown user is not_found" do
      assert UserStore.get_profile("@nobody:localhost") == {:error, :not_found}
    end
  end

  describe "get_user/1" do
    test "returns the user struct for a known user_id" do
      localpart = uniq("alice")
      {:ok, reg} = UserStore.register(localpart, "Test1234!", server_name: "localhost")
      assert {:ok, user} = UserStore.get_user(reg.user_id)
      assert user.user_id == reg.user_id
    end

    test "not_found for an unknown user_id" do
      assert UserStore.get_user("@nobody:localhost") == {:error, :not_found}
    end
  end
end
