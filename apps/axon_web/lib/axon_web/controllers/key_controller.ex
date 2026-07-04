defmodule AxonWeb.KeyController do
  use Phoenix.Controller, formats: [:json]

  action_fallback(AxonWeb.FallbackController)

  alias AxonCrypto.KeyServer
  alias AxonCore.{KeyStore, Repo, UserStore}
  alias AxonFederation.HttpClient
  import Ecto.Query
  require Logger

  # ---------------------------------------------------------------------------
  # Server keys (federation)
  # GET /_matrix/key/v2/server
  # ---------------------------------------------------------------------------

  def server_keys(conn, _params) do
    info = KeyServer.server_key_info()

    json(conn, %{
      "server_name" => info.server_name,
      "verify_keys" => %{
        info.key_id => %{"key" => info.public_key_b64}
      },
      "old_verify_keys" => %{},
      "signatures" => info.signatures,
      "valid_until_ts" => info.valid_until_ts
    })
  end

  # ---------------------------------------------------------------------------
  # E2EE key endpoints
  # ---------------------------------------------------------------------------

  # POST /_matrix/client/v3/keys/upload
  def upload(conn, params) do
    user_id = conn.assigns.current_user_id
    device_id = conn.assigns.current_device_id

    device_keys = params["device_keys"]
    one_time_keys = params["one_time_keys"] || %{}
    fallback_keys = params["fallback_keys"] || %{}

    # Store device keys and record that this user's device list changed
    if device_keys do
      upsert_device_keys(user_id, device_id, device_keys)
      record_device_list_update(user_id)
    end

    # Store one-time keys — key_id is "algorithm:key_id", e.g. "curve25519:AAAA"
    store_one_time_keys(user_id, device_id, one_time_keys)

    # Store fallback keys (one per algorithm, keyed by "algorithm:key_id" format).
    store_fallback_keys(user_id, device_id, fallback_keys)

    # Count remaining OTKs per algorithm
    counts = count_otks(user_id, device_id)
    json(conn, %{"one_time_key_counts" => counts})
  end

  # POST /_matrix/client/v3/keys/query
  def query(conn, params) do
    device_keys_req = params["device_keys"] || %{}
    user_ids = Map.keys(device_keys_req)
    current_user_id = conn.assigns.current_user_id
    local_server = Application.fetch_env!(:axon_web, :server_name)

    {local_user_ids, remote_reqs} = split_local_remote(device_keys_req, local_server)

    sigs_by_target = KeyStore.cross_signing_signatures(user_ids, current_user_id)

    local_device_keys =
      Enum.into(local_user_ids, %{}, fn queried_user_id ->
        devices =
          queried_user_id
          |> KeyStore.device_keys_for_user()
          |> Map.new(fn {device_id, key_json} ->
            {device_id,
             KeyStore.merge_signatures(key_json, queried_user_id, device_id, sigs_by_target)}
          end)

        {queried_user_id, devices}
      end)

    local_master_keys =
      KeyStore.cross_signing_keys(local_user_ids, "master")
      |> KeyStore.merge_cross_signing_key_signatures(sigs_by_target)

    local_self_signing_keys =
      KeyStore.cross_signing_keys(local_user_ids, "self_signing")
      |> KeyStore.merge_cross_signing_key_signatures(sigs_by_target)

    user_signing_keys =
      KeyStore.cross_signing_keys([current_user_id], "user_signing")
      |> KeyStore.merge_cross_signing_key_signatures(sigs_by_target)

    {remote_device_keys, remote_master_keys, remote_self_signing_keys, failures} =
      fetch_remote_keys(remote_reqs, sigs_by_target)

    json(conn, %{
      "device_keys" => Map.merge(local_device_keys, remote_device_keys),
      "master_keys" => Map.merge(local_master_keys, remote_master_keys),
      "self_signing_keys" => Map.merge(local_self_signing_keys, remote_self_signing_keys),
      "user_signing_keys" => user_signing_keys,
      "failures" => failures
    })
  end

  # Splits a %{user_id => device_ids} request map into local user_ids and a
  # %{server_name => %{user_id => device_ids}} map of remote requests.
  defp split_local_remote(device_keys_req, local_server) do
    Enum.reduce(device_keys_req, {[], %{}}, fn {user_id, device_ids}, {local, remote} ->
      server = user_id |> String.split(":") |> List.last()

      if server == local_server do
        {[user_id | local], remote}
      else
        {local,
         Map.update(remote, server, %{user_id => device_ids}, &Map.put(&1, user_id, device_ids))}
      end
    end)
  end

  # Queries each remote server once for all its users' keys, merging their
  # signatures for any cross-signing this local user performed on them.
  defp fetch_remote_keys(remote_reqs, sigs_by_target) do
    Enum.reduce(remote_reqs, {%{}, %{}, %{}, %{}}, fn {server, device_keys_map},
                                                      {dks, mks, sks, fails} ->
      case HttpClient.post(server, "/_matrix/federation/v1/user/keys/query", %{
             "device_keys" => device_keys_map
           }) do
        {:ok, resp} ->
          remote_dks =
            (resp["device_keys"] || %{})
            |> Map.new(fn {user_id, devices} ->
              merged =
                Map.new(devices, fn {device_id, key_json} ->
                  {device_id,
                   KeyStore.merge_signatures(key_json, user_id, device_id, sigs_by_target)}
                end)

              {user_id, merged}
            end)

          remote_mks =
            (resp["master_keys"] || %{})
            |> KeyStore.merge_cross_signing_key_signatures(sigs_by_target)

          remote_sks =
            (resp["self_signing_keys"] || %{})
            |> KeyStore.merge_cross_signing_key_signatures(sigs_by_target)

          {Map.merge(dks, remote_dks), Map.merge(mks, remote_mks), Map.merge(sks, remote_sks),
           fails}

        {:error, reason} ->
          Logger.warning("Federation /user/keys/query to #{server} failed: #{inspect(reason)}")
          {dks, mks, sks, Map.put(fails, server, %{})}
      end
    end)
  end

  # POST /_matrix/client/v3/keys/claim
  def claim(conn, params) do
    one_time_keys_request = params["one_time_keys"] || %{}
    local_server = Application.fetch_env!(:axon_web, :server_name)

    {local_req, remote_req} = split_local_remote(one_time_keys_request, local_server)

    local_result =
      Enum.into(local_req, %{}, fn user_id ->
        device_map = one_time_keys_request[user_id]

        device_result =
          Enum.into(device_map, %{}, fn {target_device_id, algorithm} ->
            key = KeyStore.claim_one_time_key(user_id, target_device_id, algorithm)
            {target_device_id, key || %{}}
          end)

        {user_id, device_result}
      end)

    {remote_result, failures} = claim_remote_keys(remote_req)

    json(conn, %{
      "one_time_keys" => Map.merge(local_result, remote_result),
      "failures" => failures
    })
  end

  defp claim_remote_keys(remote_req) do
    Enum.reduce(remote_req, {%{}, %{}}, fn {server, one_time_keys_map}, {acc, fails} ->
      case HttpClient.post(server, "/_matrix/federation/v1/user/keys/claim", %{
             "one_time_keys" => one_time_keys_map
           }) do
        {:ok, resp} ->
          {Map.merge(acc, resp["one_time_keys"] || %{}), fails}

        {:error, reason} ->
          Logger.warning("Federation /user/keys/claim to #{server} failed: #{inspect(reason)}")
          {acc, Map.put(fails, server, %{})}
      end
    end)
  end

  # GET /_matrix/client/v3/keys/changes
  # Returns users whose device keys changed between `from` and `to` sync tokens.
  # Uses the dl_cursor (second part of token) to query device_list_updates by id.
  def changes(conn, params) do
    user_id = conn.assigns.current_user_id
    dl_from = parse_dl_cursor(params["from"])
    dl_to = parse_dl_cursor(params["to"])

    # Include the user themselves: their own device-list changes (new logins,
    # cross-signing uploads) must be visible to their other devices.
    candidate_users = [user_id | shared_room_user_ids(user_id)]

    changed =
      Repo.all(
        from(u in "device_list_updates",
          where:
            u.user_id in ^candidate_users and
              u.id > ^dl_from and
              u.id <= ^dl_to,
          select: u.user_id,
          distinct: true
        )
      )

    json(conn, %{"changed" => changed, "left" => []})
  end

  # Extracts the dl_cursor (device-list position) from a sync token.
  # Token format: "${room_ordering}_${dl_cursor}" or plain integer (legacy → dl_cursor = 0).
  defp parse_dl_cursor(nil), do: 0

  defp parse_dl_cursor(token) do
    case String.split(token, "_", parts: 2) do
      [_, dl_s] ->
        case Integer.parse(dl_s) do
          {n, _} -> n
          _ -> 0
        end

      [_room_s] ->
        0
    end
  end

  # POST /_matrix/client/v3/keys/device_signing/upload
  # Requires UIA (m.login.dummy or m.login.password) — except when delegated
  # OIDC auth (MSC3861) is enabled, where a valid, currently-active
  # Authorization-Server-issued token is proof enough; re-auth freshness is
  # the AS's responsibility (prompt=login), not this endpoint's.
  def upload_cross_signing(conn, params) do
    user_id = conn.assigns.current_user_id
    auth = params["auth"]

    master_key = params["master_key"]
    self_signing_key = params["self_signing_key"]
    user_signing_key = params["user_signing_key"]

    cond do
      AxonWeb.Oidc.enabled?() ->
        store_cross_signing_keys(user_id, master_key, self_signing_key, user_signing_key)
        json(conn, %{})

      # MSC3967 (stable spec): UIA is skipped when either (a) the user has no
      # existing master key yet -- first-time cross-signing setup, nothing to
      # protect -- or (b) every key present in this request is byte-identical
      # to what's already stored, i.e. a pure idempotent retry (the client's
      # original 200 OK was lost in transit and it resent the same upload).
      # If anything is new or different, UIA is still required -- this is a
      # plain equality check against the DB, not a signature check, matching
      # Synapse's implementation.
      is_nil(auth) and uia_exempt?(user_id, master_key, self_signing_key, user_signing_key) ->
        store_cross_signing_keys(user_id, master_key, self_signing_key, user_signing_key)
        json(conn, %{})

      is_nil(auth) ->
        conn
        |> put_status(401)
        |> json(%{
          "error" => "Additional authentication required",
          "completed" => [],
          "session" => gen_session(),
          "flows" => [
            %{"stages" => ["m.login.password"]},
            %{"stages" => ["m.login.dummy"]}
          ],
          "params" => %{}
        })

      validate_ui_auth(user_id, auth) == :ok ->
        store_cross_signing_keys(user_id, master_key, self_signing_key, user_signing_key)
        json(conn, %{})

      true ->
        conn
        |> put_status(401)
        |> json(%{
          "errcode" => "M_FORBIDDEN",
          "error" => "Invalid credentials",
          "completed" => [],
          "session" => gen_session(),
          "flows" => [
            %{"stages" => ["m.login.password"]},
            %{"stages" => ["m.login.dummy"]}
          ],
          "params" => %{}
        })
    end
  end

  # MSC3967 exemption check. No existing master key -> always exempt (nothing
  # yet to protect). Otherwise exempt only if every key present in the
  # request equals what's already on file for that key_type -- any new or
  # changed key forces the normal UIA path.
  defp uia_exempt?(user_id, master_key, self_signing_key, user_signing_key) do
    case KeyStore.cross_signing_keys([user_id], "master")[user_id] do
      nil ->
        true

      existing_master ->
        unchanged?(master_key, existing_master) and
          unchanged?(
            self_signing_key,
            KeyStore.cross_signing_keys([user_id], "self_signing")[user_id]
          ) and
          unchanged?(
            user_signing_key,
            KeyStore.cross_signing_keys([user_id], "user_signing")[user_id]
          )
    end
  end

  # A key omitted from the request (nil) never introduces a *new* key, so
  # it's always "unchanged". Otherwise the uploaded key must exactly match
  # what's already stored.
  defp unchanged?(nil, _existing), do: true
  defp unchanged?(uploaded, existing), do: uploaded == existing

  defp store_cross_signing_keys(user_id, master_key, self_signing_key, user_signing_key) do
    # On key replacement (reset), purge stale signatures for this user so
    # clients don't see old-key sigs merged into the new key response.
    existing_key_count =
      Repo.one(
        from(k in "cross_signing_keys", where: k.user_id == ^user_id, select: count(k.user_id))
      ) || 0

    if existing_key_count > 0 do
      Repo.delete_all(
        from(s in "cross_signing_signatures",
          where: s.target_user_id == ^user_id or s.signing_user_id == ^user_id
        )
      )
    end

    for {key_type, key_json} <- [
          {"master", master_key},
          {"self_signing", self_signing_key},
          {"user_signing", user_signing_key}
        ],
        not is_nil(key_json) do
      Repo.insert_all(
        "cross_signing_keys",
        [%{user_id: user_id, key_type: key_type, key_json: key_json}],
        on_conflict: {:replace, [:key_json]},
        conflict_target: [:user_id, :key_type]
      )
    end

    record_device_list_update(user_id)
  end

  defp validate_ui_auth(_user_id, %{"type" => "m.login.dummy"}), do: :ok

  defp validate_ui_auth(current_user_id, %{"type" => "m.login.password"} = auth) do
    identifier = auth["identifier"] || %{}
    auth_user = identifier["user"] || auth["user"]
    password = auth["password"]
    server_name = Application.fetch_env!(:axon_web, :server_name)

    auth_user_id =
      if auth_user && String.starts_with?(auth_user, "@"),
        do: auth_user,
        else: "@#{auth_user}:#{server_name}"

    if auth_user_id != current_user_id do
      :error
    else
      case UserStore.get_user(current_user_id) do
        {:ok, user} ->
          if user.password_hash && Argon2.verify_pass(password, user.password_hash),
            do: :ok,
            else: :error

        _ ->
          :error
      end
    end
  end

  defp validate_ui_auth(_user_id, _auth), do: :error

  # POST /_matrix/client/v3/keys/signatures/upload
  def upload_signatures(conn, params) do
    signing_user_id = conn.assigns.current_user_id

    Enum.each(params, fn {target_user_id, key_map} ->
      Enum.each(key_map, fn {target_key_id, signed_obj} ->
        sigs = signed_obj["signatures"] || %{}

        Enum.each(sigs, fn {_signer_user_id, key_sigs} ->
          Enum.each(key_sigs, fn {signing_key_id, sig_value} ->
            Repo.insert_all(
              "cross_signing_signatures",
              [
                %{
                  target_user_id: target_user_id,
                  target_key_id: target_key_id,
                  signing_user_id: signing_user_id,
                  signing_key_id: signing_key_id,
                  signature: sig_value
                }
              ],
              on_conflict: {:replace, [:signature]},
              conflict_target: [
                :target_user_id,
                :target_key_id,
                :signing_user_id,
                :signing_key_id
              ]
            )
          end)
        end)
      end)
    end)

    json(conn, %{"failures" => %{}})
  end

  # ---------------------------------------------------------------------------
  # Key backup
  # ---------------------------------------------------------------------------

  def create_backup_version(conn, params) do
    user_id = conn.assigns.current_user_id
    algorithm = params["algorithm"]
    auth_data = params["auth_data"]

    if is_nil(algorithm) || is_nil(auth_data) do
      conn
      |> put_status(400)
      |> json(%{"errcode" => "M_MISSING_PARAM", "error" => "algorithm and auth_data required"})
    else
      %{rows: [[version]]} = Repo.query!("SELECT nextval('room_key_backup_version_seq')")
      version = Integer.to_string(version)

      Repo.insert_all("room_key_backup_versions", [
        %{
          user_id: user_id,
          version: version,
          algorithm: algorithm,
          auth_data: auth_data,
          etag: "0",
          count: 0,
          inserted_at: DateTime.utc_now(:microsecond),
          updated_at: DateTime.utc_now(:microsecond)
        }
      ])

      json(conn, %{"version" => version})
    end
  end

  def get_backup_version(conn, params) do
    user_id = conn.assigns.current_user_id
    version = params["version"]

    query =
      if version do
        from(v in "room_key_backup_versions",
          where: v.user_id == ^user_id and v.version == ^version and not v.deleted,
          select: %{
            version: v.version,
            algorithm: v.algorithm,
            auth_data: v.auth_data,
            etag: v.etag,
            count: v.count
          }
        )
      else
        from(v in "room_key_backup_versions",
          where: v.user_id == ^user_id and not v.deleted,
          order_by: [desc: v.inserted_at],
          limit: 1,
          select: %{
            version: v.version,
            algorithm: v.algorithm,
            auth_data: v.auth_data,
            etag: v.etag,
            count: v.count
          }
        )
      end

    case Repo.one(query) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "No backup version found"})

      row ->
        json(conn, %{
          "version" => row.version,
          "algorithm" => row.algorithm,
          "auth_data" => row.auth_data,
          "etag" => row.etag,
          "count" => row.count
        })
    end
  end

  def delete_backup_version(conn, %{"version" => version}) do
    user_id = conn.assigns.current_user_id

    {n, _} =
      Repo.update_all(
        from(v in "room_key_backup_versions",
          where: v.user_id == ^user_id and v.version == ^version
        ),
        set: [deleted: true]
      )

    if n > 0,
      do: json(conn, %{}),
      else:
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Version not found"})
  end

  def put_backup_keys(conn, params) do
    user_id = conn.assigns.current_user_id
    version = params["version"]
    rooms = get_in(params, ["rooms"]) || %{}

    entries =
      Enum.flat_map(rooms, fn {room_id, room_data} ->
        sessions = room_data["sessions"] || %{}

        Enum.map(sessions, fn {session_id, session_data} ->
          %{
            user_id: user_id,
            version: version,
            room_id: room_id,
            session_id: session_id,
            first_message_index: session_data["first_message_index"],
            forwarded_count: session_data["forwarded_count"] || 0,
            is_verified: session_data["is_verified"] || false,
            session_data: session_data["session_data"] || %{}
          }
        end)
      end)

    if entries != [] do
      Repo.insert_all("room_key_backups", entries,
        on_conflict:
          {:replace, [:first_message_index, :forwarded_count, :is_verified, :session_data]},
        conflict_target: [:version, :room_id, :session_id]
      )

      count =
        Repo.one(
          from(b in "room_key_backups",
            where: b.user_id == ^user_id and b.version == ^version,
            select: count(b.session_id)
          )
        )

      Repo.update_all(
        from(v in "room_key_backup_versions",
          where: v.user_id == ^user_id and v.version == ^version
        ),
        set: [count: count || 0, etag: Integer.to_string(System.os_time(:millisecond))]
      )
    end

    json(conn, %{
      "etag" => Integer.to_string(System.os_time(:millisecond)),
      "count" => length(entries)
    })
  end

  def get_backup_keys(conn, params) do
    user_id = conn.assigns.current_user_id
    version = params["version"]
    room_id = params["room_id"]
    session_id = params["session_id"]

    base =
      from(b in "room_key_backups",
        where: b.user_id == ^user_id and b.version == ^version,
        select: %{
          room_id: b.room_id,
          session_id: b.session_id,
          first_message_index: b.first_message_index,
          forwarded_count: b.forwarded_count,
          is_verified: b.is_verified,
          session_data: b.session_data
        }
      )

    base = if room_id, do: from(b in base, where: b.room_id == ^room_id), else: base
    base = if session_id, do: from(b in base, where: b.session_id == ^session_id), else: base

    rows = Repo.all(base)

    response =
      cond do
        session_id ->
          case rows do
            [] ->
              conn
              |> put_status(404)
              |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Key not found"})

            [row] ->
              json(conn, format_backup_row(row))

            _ ->
              json(conn, format_backup_row(hd(rows)))
          end

        room_id ->
          sessions =
            Enum.into(rows, %{}, fn row -> {row.session_id, format_backup_row(row)} end)

          json(conn, %{"sessions" => sessions})

        true ->
          rooms =
            rows
            |> Enum.group_by(& &1.room_id)
            |> Enum.into(%{}, fn {rid, rs} ->
              sessions = Enum.into(rs, %{}, fn r -> {r.session_id, format_backup_row(r)} end)
              {rid, %{"sessions" => sessions}}
            end)

          json(conn, %{"rooms" => rooms})
      end

    response
  end

  # PUT /_matrix/client/v3/sendToDevice/:event_type/:txn_id
  def send_to_device(conn, %{"event_type" => event_type, "txn_id" => _txn_id} = params) do
    sender_id = conn.assigns.current_user_id
    messages = get_in(params, ["messages"]) || %{}

    Enum.each(messages, fn {target_user_id, device_messages} ->
      Enum.each(device_messages, fn {target_device_id, content} ->
        Repo.insert_all("to_device_messages", [
          %{
            sender: sender_id,
            target_user_id: target_user_id,
            target_device_id: target_device_id,
            type: event_type,
            content: content,
            inserted_at: DateTime.utc_now(:microsecond)
          }
        ])
      end)
    end)

    json(conn, %{})
  end

  # ---------------------------------------------------------------------------
  # Dehydrated devices (MSC3814) — lets a client stash an extra, SSSS-encrypted
  # device server-side ahead of time so that when it's down to its last active
  # device, key backup / secret storage setup ("Key Storage") can pull Megolm
  # sessions from it instead of needing another logged-in device present.
  # ---------------------------------------------------------------------------

  # GET /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device
  def get_dehydrated_device(conn, _params) do
    user_id = conn.assigns.current_user_id

    case get_dehydrated_row(user_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "No dehydrated device available"})

      row ->
        json(conn, %{"device_id" => row.device_id, "device_data" => row.device_data})
    end
  end

  # PUT /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device
  def put_dehydrated_device(conn, params) do
    user_id = conn.assigns.current_user_id
    device_id = params["device_id"]
    device_data = params["device_data"]
    device_keys = params["device_keys"]

    cond do
      is_nil(device_id) || is_nil(device_data) ->
        conn
        |> put_status(400)
        |> json(%{
          "errcode" => "M_MISSING_PARAM",
          "error" => "device_id and device_data required"
        })

      is_nil(device_keys) ->
        conn
        |> put_status(400)
        |> json(%{
          "errcode" => "M_MISSING_PARAM",
          "error" => "Device key(s) not found, these must be provided."
        })

      true ->
        # Each user has at most one dehydrated device — replacing it discards the old one.
        if old = get_dehydrated_row(user_id) do
          purge_device(user_id, old.device_id)
        end

        UserStore.ensure_device(user_id, device_id, params["initial_device_display_name"])
        upsert_device_keys(user_id, device_id, device_keys)
        store_one_time_keys(user_id, device_id, params["one_time_keys"] || %{})
        store_fallback_keys(user_id, device_id, params["fallback_keys"] || %{})
        record_device_list_update(user_id)

        Repo.insert_all(
          "dehydrated_devices",
          [
            %{
              user_id: user_id,
              device_id: device_id,
              device_data: device_data,
              inserted_at: DateTime.utc_now(:microsecond),
              updated_at: DateTime.utc_now(:microsecond)
            }
          ],
          on_conflict: {:replace, [:device_id, :device_data, :updated_at]},
          conflict_target: [:user_id]
        )

        json(conn, %{"device_id" => device_id})
    end
  end

  # DELETE /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device
  def delete_dehydrated_device(conn, _params) do
    user_id = conn.assigns.current_user_id

    case get_dehydrated_row(user_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{"errcode" => "M_NOT_FOUND", "error" => "No dehydrated device available"})

      row ->
        purge_device(user_id, row.device_id)
        Repo.delete_all(from(d in "dehydrated_devices", where: d.user_id == ^user_id))
        json(conn, %{"device_id" => row.device_id})
    end
  end

  # GET /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device/:device_id/events
  def get_dehydrated_device_events(conn, %{"device_id" => device_id} = params) do
    respond_with_dehydrated_events(conn, device_id, params["from"], params["limit"], false)
  end

  # POST .../dehydrated_device/:device_id/events — deprecated pre-final-MSC3814
  # draft shape, kept only for older clients that still send it.
  def post_dehydrated_device_events(conn, %{"device_id" => device_id} = params) do
    respond_with_dehydrated_events(conn, device_id, params["next_batch"], params["limit"], true)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp upsert_device_keys(user_id, device_id, device_keys) do
    Repo.insert_all(
      "device_keys",
      [
        %{
          user_id: user_id,
          device_id: device_id,
          keys: device_keys["keys"] || %{},
          algorithms: device_keys["algorithms"] || [],
          signatures: device_keys["signatures"] || %{},
          inserted_at: DateTime.utc_now(:microsecond),
          updated_at: DateTime.utc_now(:microsecond)
        }
      ],
      on_conflict: {:replace, [:keys, :algorithms, :signatures, :updated_at]},
      conflict_target: [:user_id, :device_id]
    )
  end

  defp gen_session, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp format_backup_row(row) do
    %{
      "first_message_index" => row.first_message_index,
      "forwarded_count" => row.forwarded_count,
      "is_verified" => row.is_verified,
      "session_data" => row.session_data
    }
  end

  defp count_otks(user_id, device_id) do
    Repo.all(
      from(k in "one_time_keys",
        where: k.user_id == ^user_id and k.device_id == ^device_id and k.claimed == false,
        group_by: k.algorithm,
        select: {k.algorithm, count(k.id)}
      )
    )
    |> Enum.into(%{})
  end

  defp record_device_list_update(user_id), do: KeyStore.record_device_list_update(user_id)

  defp shared_room_user_ids(user_id) do
    Repo.all(
      from(m2 in "room_memberships",
        join: m1 in "room_memberships",
        on: m1.room_id == m2.room_id and m1.user_id == ^user_id and m1.membership == "join",
        where: m2.membership == "join" and m2.user_id != ^user_id,
        select: m2.user_id,
        distinct: true
      )
    )
  end

  defp store_one_time_keys(user_id, device_id, one_time_keys) do
    Enum.each(one_time_keys, fn {key_id, key_json} ->
      algorithm = key_id |> String.split(":", parts: 2) |> hd()

      Repo.insert_all(
        "one_time_keys",
        [
          %{
            user_id: user_id,
            device_id: device_id,
            algorithm: algorithm,
            key_id: key_id,
            key_json: key_json,
            claimed: false,
            inserted_at: DateTime.utc_now(:microsecond)
          }
        ],
        on_conflict: :nothing
      )
    end)
  end

  # Extracts just the algorithm name ("signed_curve25519") from the full key id
  # ("signed_curve25519:AAAAAAAAAAA") so the algorithm column stays correct and
  # each new upload overwrites the previous fallback for that algorithm.
  defp store_fallback_keys(user_id, device_id, fallback_keys) do
    Enum.each(fallback_keys, fn {full_key_id, key_json} ->
      algorithm = full_key_id |> String.split(":", parts: 2) |> hd()

      Repo.insert_all(
        "fallback_keys",
        [
          %{
            user_id: user_id,
            device_id: device_id,
            algorithm: algorithm,
            key_id: full_key_id,
            key_json: key_json,
            used: false
          }
        ],
        on_conflict: {:replace, [:key_id, :key_json, :used]},
        conflict_target: [:user_id, :device_id, :algorithm]
      )
    end)
  end

  defp get_dehydrated_row(user_id) do
    Repo.one(
      from(d in "dehydrated_devices",
        where: d.user_id == ^user_id,
        select: %{device_id: d.device_id, device_data: d.device_data}
      )
    )
  end

  # Tears down everything tied to a superseded/removed dehydrated device: its
  # device row, its keys, and any to-device messages already queued for it
  # (nothing will ever rehydrate that device_id again, so nothing should keep
  # addressing it). Delegates to the shared AxonCore.KeyStore.purge_device/2
  # so this cleanup stays in one place (also used by logout / device deletion).
  defp purge_device(user_id, device_id), do: KeyStore.purge_device(user_id, device_id)

  defp respond_with_dehydrated_events(
         conn,
         device_id,
         since_token,
         limit_param,
         always_include_next_batch
       ) do
    user_id = conn.assigns.current_user_id

    case get_dehydrated_row(user_id) do
      nil ->
        conn
        |> put_status(403)
        |> json(%{"errcode" => "M_FORBIDDEN", "error" => "No dehydrated device exists"})

      %{device_id: ^device_id} ->
        case parse_since(since_token) do
          {:ok, since_id} ->
            limit = parse_limit(limit_param)

            {events, last_id, to_token} =
              fetch_dehydrated_events(user_id, device_id, since_id, limit)

            limited = last_id != to_token

            body =
              if limited or always_include_next_batch do
                %{"events" => events, "next_batch" => Integer.to_string(last_id)}
              else
                %{"events" => events}
              end

            json(conn, body)

          :error ->
            conn
            |> put_status(400)
            |> json(%{
              "errcode" => "M_INVALID_PARAM",
              "error" => "from parameter has an invalid format"
            })
        end

      _other ->
        conn
        |> put_status(403)
        |> json(%{
          "errcode" => "M_FORBIDDEN",
          "error" => "You may only fetch messages for your dehydrated device"
        })
    end
  end

  # Fetches to-device messages queued for the dehydrated device between
  # `since_id` (exclusive) and a token snapshotted at the start of the call
  # (inclusive), so a message arriving mid-scan is deferred to the next batch
  # rather than racily included or dropped. Returns `to_token` as `last_id`
  # whenever fewer than `limit` rows were found — meaning the scan reached the
  # snapshot boundary — which signals "no more messages" even though no actual
  # row carries that id.
  defp fetch_dehydrated_events(user_id, device_id, since_id, limit) do
    to_token = Repo.one(from(m in "to_device_messages", select: max(m.id))) || 0

    rows =
      Repo.all(
        from(m in "to_device_messages",
          where:
            m.target_user_id == ^user_id and m.target_device_id == ^device_id and
              m.id > ^since_id and m.id <= ^to_token,
          order_by: [asc: m.id],
          limit: ^limit,
          select: %{id: m.id, sender: m.sender, type: m.type, content: m.content}
        )
      )

    last_id = if length(rows) == limit, do: List.last(rows).id, else: to_token

    events =
      Enum.map(rows, fn r -> %{"type" => r.type, "sender" => r.sender, "content" => r.content} end)

    {events, last_id, to_token}
  end

  defp parse_since(nil), do: {:ok, 0}

  defp parse_since(token) do
    case Integer.parse(token) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, ""} when n > 0 -> n
      _ -> 100
    end
  end

  defp parse_limit(_), do: 100
end
