defmodule AxonWeb.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_query_params
  end

  pipeline :authenticated do
    plug :accepts, ["json"]
    plug :fetch_query_params
    plug AxonWeb.Plug.AuthenticateToken
  end

  # -------------------------------------------------------------------------
  # Discovery — no auth
  # -------------------------------------------------------------------------
  scope "/_matrix/client", AxonWeb do
    pipe_through :api

    get "/versions", VersionController, :versions

    # Auth
    get "/v3/login", AuthController, :login_types
    post "/v3/login", AuthController, :login
    post "/v3/register", AuthController, :register
    get "/v3/register/available", AuthController, :register_available

    # Public profile (no auth needed per spec)
    get "/v3/profile/:user_id", ProfileController, :show
    get "/v3/profile/:user_id/displayname", ProfileController, :get_displayname
    get "/v3/profile/:user_id/avatar_url", ProfileController, :get_avatar_url

    # Public room directory
    get "/v3/publicRooms", DirectoryController, :public_rooms
    post "/v3/publicRooms", DirectoryController, :public_rooms
    get "/v3/directory/room/:room_alias", DirectoryController, :get_alias
  end

  # -------------------------------------------------------------------------
  # Synapse admin registration (no auth — uses HMAC MAC for auth)
  # -------------------------------------------------------------------------
  scope "/_synapse/admin/v1", AxonWeb do
    pipe_through :api

    get "/register", AuthController, :synapse_nonce
    post "/register", AuthController, :synapse_register
  end

  # -------------------------------------------------------------------------
  # Server key endpoint (no auth)
  # -------------------------------------------------------------------------
  scope "/_matrix/key", AxonWeb do
    pipe_through :api

    get "/v2/server", KeyController, :server_keys
    get "/v2/server/:key_id", KeyController, :server_keys
  end

  # -------------------------------------------------------------------------
  # Authenticated CS API
  # -------------------------------------------------------------------------
  scope "/_matrix/client", AxonWeb do
    pipe_through :authenticated

    # Account
    get "/v3/capabilities", VersionController, :capabilities
    post "/v3/logout", AuthController, :logout
    post "/v3/logout/all", AuthController, :logout_all
    get "/v3/account/whoami", AuthController, :whoami
    post "/v3/account/password", AuthController, :change_password
    post "/v3/account/deactivate", AuthController, :deactivate

    # Profile
    put "/v3/profile/:user_id/displayname", ProfileController, :set_displayname
    put "/v3/profile/:user_id/avatar_url", ProfileController, :set_avatar_url

    # Rooms
    post "/v3/createRoom", RoomController, :create
    get "/v3/joined_rooms", RoomController, :joined_rooms
    post "/v3/join/:room_id", RoomController, :join
    post "/v3/rooms/:room_id/join", RoomController, :join
    post "/v3/rooms/:room_id/leave", RoomController, :leave
    post "/v3/rooms/:room_id/invite", RoomController, :invite
    post "/v3/rooms/:room_id/kick", RoomController, :kick
    post "/v3/rooms/:room_id/ban", RoomController, :ban
    post "/v3/rooms/:room_id/unban", RoomController, :unban

    # Room members & aliases
    get "/v3/rooms/:room_id/members", RoomController, :members
    get "/v3/rooms/:room_id/joined_members", RoomController, :joined_members
    get "/v3/rooms/:room_id/aliases", DirectoryController, :list_room_aliases
    post "/v3/rooms/:room_id/forget", RoomController, :forget

    # Events
    put "/v3/rooms/:room_id/send/:event_type/:txn_id", EventController, :send_event
    put "/v3/rooms/:room_id/state/:event_type", EventController, :send_state_event
    put "/v3/rooms/:room_id/state/:event_type/:state_key", EventController, :send_state_event
    get "/v3/rooms/:room_id/state", EventController, :get_state
    get "/v3/rooms/:room_id/state/:event_type", EventController, :get_state_event
    get "/v3/rooms/:room_id/state/:event_type/:state_key", EventController, :get_state_event
    get "/v3/rooms/:room_id/event/:event_id", EventController, :get_event
    get "/v3/rooms/:room_id/messages", EventController, :get_messages
    put "/v3/rooms/:room_id/redact/:event_id/:txn_id", EventController, :redact

    # Sync
    get "/v3/sync", SyncController, :sync

    # Directory (mutations require auth)
    put "/v3/directory/room/:room_alias", DirectoryController, :put_alias
    delete "/v3/directory/room/:room_alias", DirectoryController, :delete_alias

    # Filters
    post "/v3/user/:user_id/filter", FilterController, :create
    get "/v3/user/:user_id/filter/:filter_id", FilterController, :get

    # Account data
    get "/v3/user/:user_id/account_data/:type", AccountDataController, :get
    put "/v3/user/:user_id/account_data/:type", AccountDataController, :put
    get "/v3/user/:user_id/rooms/:room_id/account_data/:type", AccountDataController, :get_room
    put "/v3/user/:user_id/rooms/:room_id/account_data/:type", AccountDataController, :put_room

    # Devices
    get "/v3/devices", DeviceController, :index
    get "/v3/devices/:device_id", DeviceController, :show
    put "/v3/devices/:device_id", DeviceController, :update
    delete "/v3/devices/:device_id", DeviceController, :delete

    # Receipts & read markers
    post "/v3/rooms/:room_id/receipt/:receipt_type/:event_id", ReceiptController, :receipt
    post "/v3/rooms/:room_id/read_markers", ReceiptController, :read_markers

    # E2EE
    post "/v3/keys/upload", KeyController, :upload
    post "/v3/keys/query", KeyController, :query
    post "/v3/keys/claim", KeyController, :claim
    get "/v3/keys/changes", KeyController, :changes
    put "/v3/sendToDevice/:event_type/:txn_id", KeyController, :send_to_device
  end
end
