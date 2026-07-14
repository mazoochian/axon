defmodule AxonWeb.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug(:accepts, ["json"])
    plug(:fetch_query_params)
  end

  pipeline :authenticated do
    plug(:accepts, ["json"])
    plug(:fetch_query_params)
    plug(AxonWeb.Plug.AuthenticateToken)
  end

  pipeline :admin do
    plug(:accepts, ["json"])
    plug(:fetch_query_params)
    plug(AxonWeb.Plug.AuthenticateToken)
    plug(AxonWeb.Plug.RequireAdmin)
  end

  # -------------------------------------------------------------------------
  # Discovery — no auth
  # -------------------------------------------------------------------------
  scope "/_matrix/client", AxonWeb do
    pipe_through(:api)

    get("/versions", VersionController, :versions)

    # Auth
    get("/v3/login", AuthController, :login_types)
    post("/v3/login", AuthController, :login)
    post("/v3/register", AuthController, :register)
    get("/v3/register/available", AuthController, :register_available)

    # OAuth2/OIDC discovery (MSC2965) — returns the AS's metadata when
    # delegated auth is configured, else 404 M_UNRECOGNIZED
    get("/v1/auth_metadata", VersionController, :auth_metadata)

    # Media config (no auth required)
    get("/v3/media/config", VersionController, :media_config)
    get("/r0/media/config", VersionController, :media_config)

    # Public profile (no auth needed per spec)
    get("/v3/profile/:user_id", ProfileController, :show)
    get("/v3/profile/:user_id/displayname", ProfileController, :get_displayname)
    get("/v3/profile/:user_id/avatar_url", ProfileController, :get_avatar_url)

    # Public room directory
    get("/v3/publicRooms", DirectoryController, :public_rooms)
    post("/v3/publicRooms", DirectoryController, :public_rooms)
    get("/v3/directory/room/:room_alias", DirectoryController, :get_alias)
  end

  # -------------------------------------------------------------------------
  # r0 compatibility aliases (unauthenticated)
  # -------------------------------------------------------------------------
  scope "/_matrix/client", AxonWeb do
    pipe_through(:api)

    get("/r0/login", AuthController, :login_types)
    post("/r0/login", AuthController, :login)
    post("/r0/register", AuthController, :register)
    get("/r0/register/available", AuthController, :register_available)
    get("/r0/profile/:user_id", ProfileController, :show)
    get("/r0/profile/:user_id/displayname", ProfileController, :get_displayname)
    get("/r0/profile/:user_id/avatar_url", ProfileController, :get_avatar_url)
    get("/r0/publicRooms", DirectoryController, :public_rooms)
    post("/r0/publicRooms", DirectoryController, :public_rooms)
    get("/r0/directory/room/:room_alias", DirectoryController, :get_alias)
  end

  # -------------------------------------------------------------------------
  # r0 compatibility aliases (authenticated)
  # -------------------------------------------------------------------------
  scope "/_matrix/client", AxonWeb do
    pipe_through(:authenticated)

    get("/r0/capabilities", VersionController, :capabilities)
    post("/r0/logout", AuthController, :logout)
    post("/r0/logout/all", AuthController, :logout_all)
    get("/r0/account/whoami", AuthController, :whoami)
    post("/r0/account/password", AuthController, :change_password)
    post("/r0/account/deactivate", AuthController, :deactivate)
    put("/r0/profile/:user_id/displayname", ProfileController, :set_displayname)
    put("/r0/profile/:user_id/avatar_url", ProfileController, :set_avatar_url)
    post("/r0/createRoom", RoomController, :create)
    get("/r0/joined_rooms", RoomController, :joined_rooms)
    post("/r0/join/:room_id", RoomController, :join)
    post("/r0/rooms/:room_id/join", RoomController, :join)
    post("/r0/rooms/:room_id/leave", RoomController, :leave)
    post("/r0/rooms/:room_id/invite", RoomController, :invite)
    post("/r0/rooms/:room_id/kick", RoomController, :kick)
    post("/r0/rooms/:room_id/ban", RoomController, :ban)
    post("/r0/rooms/:room_id/unban", RoomController, :unban)
    get("/r0/rooms/:room_id/members", RoomController, :members)
    get("/r0/rooms/:room_id/joined_members", RoomController, :joined_members)
    get("/r0/rooms/:room_id/aliases", DirectoryController, :list_room_aliases)
    post("/r0/rooms/:room_id/forget", RoomController, :forget)
    put("/r0/rooms/:room_id/send/:event_type/:txn_id", EventController, :send_event)
    put("/r0/rooms/:room_id/state/:event_type", EventController, :send_state_event)
    put("/r0/rooms/:room_id/state/:event_type/:state_key", EventController, :send_state_event)
    get("/r0/rooms/:room_id/state", EventController, :get_state)
    get("/r0/rooms/:room_id/state/:event_type", EventController, :get_state_event)
    get("/r0/rooms/:room_id/state/:event_type/:state_key", EventController, :get_state_event)
    get("/r0/rooms/:room_id/event/:event_id", EventController, :get_event)
    get("/r0/rooms/:room_id/messages", EventController, :get_messages)
    put("/r0/rooms/:room_id/redact/:event_id/:txn_id", EventController, :redact)
    get("/r0/sync", SyncController, :sync)
    put("/r0/directory/room/:room_alias", DirectoryController, :put_alias)
    delete("/r0/directory/room/:room_alias", DirectoryController, :delete_alias)
    put("/r0/directory/list/room/:room_id", DirectoryController, :set_room_visibility)
    post("/r0/user/:user_id/filter", FilterController, :create)
    get("/r0/user/:user_id/filter/:filter_id", FilterController, :get)
    get("/r0/user/:user_id/account_data/:type", AccountDataController, :get)
    put("/r0/user/:user_id/account_data/:type", AccountDataController, :put)
    get("/r0/user/:user_id/rooms/:room_id/account_data/:type", AccountDataController, :get_room)
    put("/r0/user/:user_id/rooms/:room_id/account_data/:type", AccountDataController, :put_room)
    get("/r0/devices", DeviceController, :index)
    get("/r0/devices/:device_id", DeviceController, :show)
    put("/r0/devices/:device_id", DeviceController, :update)
    delete("/r0/devices/:device_id", DeviceController, :delete)
    post("/r0/rooms/:room_id/receipt/:receipt_type/:event_id", ReceiptController, :receipt)
    post("/r0/rooms/:room_id/read_markers", ReceiptController, :read_markers)
    post("/r0/keys/upload", KeyController, :upload)
    post("/r0/keys/query", KeyController, :query)
    post("/r0/keys/claim", KeyController, :claim)
    get("/r0/keys/changes", KeyController, :changes)
    put("/r0/sendToDevice/:event_type/:txn_id", KeyController, :send_to_device)
  end

  # -------------------------------------------------------------------------
  # Synapse admin registration (no auth — uses HMAC MAC for auth)
  # -------------------------------------------------------------------------
  scope "/_synapse/admin/v1", AxonWeb do
    pipe_through(:api)

    get("/register", AuthController, :synapse_nonce)
    post("/register", AuthController, :synapse_register)
  end

  # -------------------------------------------------------------------------
  # Admin API (Phase 13) — gated by AxonWeb.Plug.RequireAdmin
  # -------------------------------------------------------------------------
  scope "/_synapse/admin/v1", AxonWeb do
    pipe_through(:admin)

    get("/users", AdminController, :list_users)
    get("/users/:user_id", AdminController, :get_user)
    post("/deactivate/:user_id", AdminController, :deactivate_user)
    post("/users/:user_id/shadow_ban", AdminController, :shadow_ban)
    delete("/users/:user_id/shadow_ban", AdminController, :unshadow_ban)

    get("/rooms", AdminController, :list_rooms)
    get("/rooms/:room_id", AdminController, :get_room)
    delete("/rooms/:room_id", AdminController, :purge_room)

    post("/media/quarantine/:server_name/:media_id", AdminController, :quarantine_media)
    delete("/media/quarantine/:server_name/:media_id", AdminController, :unquarantine_media)

    get("/event_reports", AdminController, :list_reports)
  end

  # -------------------------------------------------------------------------
  # Server key endpoint (no auth)
  # -------------------------------------------------------------------------
  scope "/_matrix/key", AxonWeb do
    pipe_through(:api)

    get("/v2/server", KeyController, :server_keys)
    get("/v2/server/:key_id", KeyController, :server_keys)
  end

  scope "/_matrix/media", AxonWeb do
    pipe_through(:api)
    get("/v3/config", VersionController, :media_config)
    get("/r0/config", VersionController, :media_config)
    get("/v3/download/:server_name/:media_id", MediaController, :download)
    get("/v3/download/:server_name/:media_id/:filename", MediaController, :download)
    get("/v3/thumbnail/:server_name/:media_id", MediaController, :thumbnail)
    get("/r0/download/:server_name/:media_id", MediaController, :download)
    get("/r0/download/:server_name/:media_id/:filename", MediaController, :download)
    get("/r0/thumbnail/:server_name/:media_id", MediaController, :thumbnail)
  end

  # Upload requires auth per spec (unlike legacy download/thumbnail above,
  # which stay unauthenticated for old-client compatibility).
  scope "/_matrix/media", AxonWeb do
    pipe_through(:authenticated)
    post("/v3/upload", MediaController, :upload)
    post("/r0/upload", MediaController, :upload)
  end

  # -------------------------------------------------------------------------
  # Application Service inbound transactions (AS auth via token)
  # -------------------------------------------------------------------------
  scope "/_matrix/app/v1", AxonWeb do
    pipe_through(:api)
    put("/transactions/:txn_id", AppServiceController, :transaction)
  end

  # -------------------------------------------------------------------------
  # Federation API — inbound from remote servers (X-Matrix auth)
  # -------------------------------------------------------------------------
  pipeline :federation do
    plug(:accepts, ["json"])
    plug(:fetch_query_params)
    plug(AxonWeb.Plug.FederationAuth)
  end

  scope "/_matrix/federation", AxonWeb do
    pipe_through(:federation)

    put("/v1/send/:txn_id", FederationController, :send_transaction)
    get("/v1/make_join/:room_id/:user_id", FederationController, :make_join)
    put("/v2/send_join/:room_id/:event_id", FederationController, :send_join)
    put("/v1/send_join/:room_id/:event_id", FederationController, :send_join)
    get("/v1/make_leave/:room_id/:user_id", FederationController, :make_leave)
    put("/v2/send_leave/:room_id/:event_id", FederationController, :send_leave)
    put("/v1/send_leave/:room_id/:event_id", FederationController, :send_leave)
    get("/v1/event/:event_id", FederationController, :get_event)
    get("/v1/state/:room_id", FederationController, :get_state)
    get("/v1/state_ids/:room_id", FederationController, :get_state_ids)
    get("/v1/backfill/:room_id", FederationController, :backfill)
    post("/v1/get_missing_events/:room_id", FederationController, :get_missing_events)
    get("/v1/query/directory", FederationController, :query_directory)
    get("/v1/query/profile", FederationController, :query_profile)

    # E2EE cross-server key exchange
    post("/v1/user/keys/query", FederationController, :query_user_keys)
    post("/v1/user/keys/claim", FederationController, :claim_user_keys)
    get("/v1/user/devices/:user_id", FederationController, :get_user_devices)

    # Knock — restricted/knock join rules (MSC2403)
    get("/v1/make_knock/:room_id/:user_id", FederationController, :make_knock)
    put("/v1/send_knock/:room_id/:event_id", FederationController, :send_knock)
  end

  scope "/_matrix/key", AxonWeb do
    pipe_through(:federation)

    post("/v2/query", FederationController, :query_keys)
    get("/v2/query/:server_name/:key_id", FederationController, :query_keys)
  end

  # -------------------------------------------------------------------------
  # Authenticated CS API
  # -------------------------------------------------------------------------
  scope "/_matrix/client", AxonWeb do
    pipe_through(:authenticated)

    # Account
    get("/v3/capabilities", VersionController, :capabilities)
    post("/v3/logout", AuthController, :logout)
    post("/v3/logout/all", AuthController, :logout_all)
    get("/v3/account/whoami", AuthController, :whoami)
    post("/v3/account/password", AuthController, :change_password)
    post("/v3/account/deactivate", AuthController, :deactivate)

    # Profile
    put("/v3/profile/:user_id/displayname", ProfileController, :set_displayname)
    put("/v3/profile/:user_id/avatar_url", ProfileController, :set_avatar_url)

    # Rooms
    post("/v3/createRoom", RoomController, :create)
    get("/v3/joined_rooms", RoomController, :joined_rooms)
    post("/v3/join/:room_id", RoomController, :join)
    post("/v3/rooms/:room_id/join", RoomController, :join)
    post("/v3/rooms/:room_id/leave", RoomController, :leave)
    post("/v3/rooms/:room_id/invite", RoomController, :invite)
    post("/v3/rooms/:room_id/kick", RoomController, :kick)
    post("/v3/rooms/:room_id/ban", RoomController, :ban)
    post("/v3/rooms/:room_id/unban", RoomController, :unban)
    post("/v3/knock/:room_id_or_alias", RoomController, :knock)
    post("/v3/rooms/:room_id/knock", RoomController, :knock)
    post("/r0/knock/:room_id_or_alias", RoomController, :knock)
    post("/r0/rooms/:room_id/knock", RoomController, :knock)

    # Reporting
    post("/v3/rooms/:room_id/report/:event_id", ReportController, :report_event)
    post("/r0/rooms/:room_id/report/:event_id", ReportController, :report_event)
    post("/v3/rooms/:room_id/report", ReportController, :report_room)

    # Presence
    get("/v3/presence/:user_id/status", PresenceController, :get_status)
    put("/v3/presence/:user_id/status", PresenceController, :put_status)
    get("/r0/presence/:user_id/status", PresenceController, :get_status)
    put("/r0/presence/:user_id/status", PresenceController, :put_status)

    # Search
    post("/v3/search", SearchController, :search)
    post("/r0/search", SearchController, :search)

    # Room members & aliases
    get("/v3/rooms/:room_id/members", RoomController, :members)
    get("/v3/rooms/:room_id/joined_members", RoomController, :joined_members)
    get("/v3/rooms/:room_id/aliases", DirectoryController, :list_room_aliases)
    post("/v3/rooms/:room_id/forget", RoomController, :forget)
    post("/v3/rooms/:room_id/upgrade", RoomController, :upgrade)

    # Events
    put("/v3/rooms/:room_id/send/:event_type/:txn_id", EventController, :send_event)
    put("/v3/rooms/:room_id/state/:event_type", EventController, :send_state_event)
    put("/v3/rooms/:room_id/state/:event_type/:state_key", EventController, :send_state_event)
    get("/v3/rooms/:room_id/state", EventController, :get_state)
    get("/v3/rooms/:room_id/state/:event_type", EventController, :get_state_event)
    get("/v3/rooms/:room_id/state/:event_type/:state_key", EventController, :get_state_event)
    get("/v3/rooms/:room_id/event/:event_id", EventController, :get_event)
    get("/v3/rooms/:room_id/messages", EventController, :get_messages)
    put("/v3/rooms/:room_id/redact/:event_id/:txn_id", EventController, :redact)

    # Relations (reactions, threads) — Phase 5
    get("/v1/rooms/:room_id/relations/:event_id", EventController, :get_relations)
    get("/v1/rooms/:room_id/relations/:event_id/:rel_type", EventController, :get_relations)

    get(
      "/v1/rooms/:room_id/relations/:event_id/:rel_type/:event_type",
      EventController,
      :get_relations
    )

    # Spaces — Phase 5
    get("/v1/rooms/:room_id/hierarchy", SpaceController, :hierarchy)

    # Sync
    get("/v3/sync", SyncController, :sync)

    # Sliding sync (MSC4186) — unstable prefix per MSC, not yet a stable
    # spec endpoint (would land at /v5/sync when stabilized).
    post("/unstable/org.matrix.msc4186/sync", SlidingSyncController, :sync)

    # Directory (mutations require auth)
    put("/v3/directory/room/:room_alias", DirectoryController, :put_alias)
    delete("/v3/directory/room/:room_alias", DirectoryController, :delete_alias)
    put("/v3/directory/list/room/:room_id", DirectoryController, :set_room_visibility)

    # Filters
    post("/v3/user/:user_id/filter", FilterController, :create)
    get("/v3/user/:user_id/filter/:filter_id", FilterController, :get)

    # Account data
    get("/v3/user/:user_id/account_data/:type", AccountDataController, :get)
    put("/v3/user/:user_id/account_data/:type", AccountDataController, :put)
    get("/v3/user/:user_id/rooms/:room_id/account_data/:type", AccountDataController, :get_room)
    put("/v3/user/:user_id/rooms/:room_id/account_data/:type", AccountDataController, :put_room)

    # Devices
    get("/v3/devices", DeviceController, :index)
    get("/v3/devices/:device_id", DeviceController, :show)
    put("/v3/devices/:device_id", DeviceController, :update)
    delete("/v3/devices/:device_id", DeviceController, :delete)
    post("/v3/delete_devices", DeviceController, :delete_devices)
    post("/r0/delete_devices", DeviceController, :delete_devices)

    # Pushers
    get("/v3/pushers", PusherController, :index)
    post("/v3/pushers/set", PusherController, :set)
    get("/r0/pushers", PusherController, :index)
    post("/r0/pushers/set", PusherController, :set)

    # Media upload (auth required per spec)
    post("/v3/media/upload", MediaController, :upload)
    get("/v1/media/download/:server_name/:media_id", MediaController, :download)
    get("/v1/media/download/:server_name/:media_id/:filename", MediaController, :download)
    get("/v1/media/thumbnail/:server_name/:media_id", MediaController, :thumbnail)
    get("/v3/media/preview_url", MediaController, :url_preview)

    # Third-party identifiers (stub)
    get("/v3/account/3pid", VersionController, :empty_list_3pid)
    post("/v3/account/3pid", VersionController, :empty_ok)
    get("/r0/account/3pid", VersionController, :empty_list_3pid)

    # Receipts & read markers
    post("/v3/rooms/:room_id/receipt/:receipt_type/:event_id", ReceiptController, :receipt)
    post("/v3/rooms/:room_id/read_markers", ReceiptController, :read_markers)

    # Typing
    put("/v3/rooms/:room_id/typing/:user_id", RoomController, :typing)
    put("/r0/rooms/:room_id/typing/:user_id", RoomController, :typing)

    # E2EE
    post("/v3/keys/upload", KeyController, :upload)
    post("/v3/keys/query", KeyController, :query)
    post("/v3/keys/claim", KeyController, :claim)
    get("/v3/keys/changes", KeyController, :changes)
    put("/v3/sendToDevice/:event_type/:txn_id", KeyController, :send_to_device)
    post("/v3/keys/device_signing/upload", KeyController, :upload_cross_signing)
    post("/v3/keys/signatures/upload", KeyController, :upload_signatures)
    post("/r0/keys/device_signing/upload", KeyController, :upload_cross_signing)
    post("/r0/keys/signatures/upload", KeyController, :upload_signatures)

    # Key backup
    post("/v3/room_keys/version", KeyController, :create_backup_version)
    get("/v3/room_keys/version", KeyController, :get_backup_version)
    get("/v3/room_keys/version/:version", KeyController, :get_backup_version)
    delete("/v3/room_keys/version/:version", KeyController, :delete_backup_version)
    put("/v3/room_keys/keys/:room_id/:session_id", KeyController, :put_backup_keys)
    get("/v3/room_keys/keys/:room_id/:session_id", KeyController, :get_backup_keys)
    put("/v3/room_keys/keys/:room_id", KeyController, :put_backup_keys)
    get("/v3/room_keys/keys/:room_id", KeyController, :get_backup_keys)
    put("/v3/room_keys/keys", KeyController, :put_backup_keys)
    get("/v3/room_keys/keys", KeyController, :get_backup_keys)

    # Dehydrated devices (MSC3814) — server-side stash used to bootstrap
    # "Key Storage" when the client has no other logged-in device to hand.
    get(
      "/unstable/org.matrix.msc3814.v1/dehydrated_device",
      KeyController,
      :get_dehydrated_device
    )

    put(
      "/unstable/org.matrix.msc3814.v1/dehydrated_device",
      KeyController,
      :put_dehydrated_device
    )

    delete(
      "/unstable/org.matrix.msc3814.v1/dehydrated_device",
      KeyController,
      :delete_dehydrated_device
    )

    get(
      "/unstable/org.matrix.msc3814.v1/dehydrated_device/:device_id/events",
      KeyController,
      :get_dehydrated_device_events
    )

    post(
      "/unstable/org.matrix.msc3814.v1/dehydrated_device/:device_id/events",
      KeyController,
      :post_dehydrated_device_events
    )

    # User directory
    post("/v3/user_directory/search", UserDirectoryController, :search)
    post("/r0/user_directory/search", UserDirectoryController, :search)

    # Push rules
    get("/v3/pushrules/", PushRulesController, :index)
    get("/v3/pushrules/:scope/", PushRulesController, :get_scope)
    get("/v3/pushrules/:scope/:kind/:rule_id", PushRulesController, :get_rule)
    put("/v3/pushrules/:scope/:kind/:rule_id", PushRulesController, :put_rule)
    delete("/v3/pushrules/:scope/:kind/:rule_id", PushRulesController, :delete_rule)
    put("/v3/pushrules/:scope/:kind/:rule_id/enabled", PushRulesController, :put_rule_enabled)
    put("/v3/pushrules/:scope/:kind/:rule_id/actions", PushRulesController, :put_rule_actions)
    get("/r0/pushrules/", PushRulesController, :index)
    get("/r0/pushrules/:scope/", PushRulesController, :get_scope)
    get("/r0/pushrules/:scope/:kind/:rule_id", PushRulesController, :get_rule)
    put("/r0/pushrules/:scope/:kind/:rule_id", PushRulesController, :put_rule)
    delete("/r0/pushrules/:scope/:kind/:rule_id", PushRulesController, :delete_rule)
  end
end
