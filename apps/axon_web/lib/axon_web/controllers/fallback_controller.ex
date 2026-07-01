defmodule AxonWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(404)
    |> json(%{"errcode" => "M_NOT_FOUND", "error" => "Not found"})
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Forbidden"})
  end

  def call(conn, {:error, :user_in_use}) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_USER_IN_USE", "error" => "User ID already taken"})
  end

  def call(conn, {:error, :invalid_input}) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_INVALID_PARAM", "error" => "Invalid input"})
  end

  def call(conn, {:error, :not_joined}) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not a member of the room"})
  end

  def call(conn, {:error, :insufficient_power}) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Insufficient power level"})
  end

  def call(conn, {:error, :room_already_created}) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_ROOM_IN_USE", "error" => "Room already exists"})
  end

  def call(conn, {:error, :unsupported_room_version}) do
    conn
    |> put_status(400)
    |> json(%{
      "errcode" => "M_UNSUPPORTED_ROOM_VERSION",
      "error" => "Room version not supported"
    })
  end

  def call(conn, {:error, :banned}) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "User is banned from this room"})
  end

  def call(conn, {:error, :not_invited}) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Not invited to this room"})
  end

  def call(conn, {:error, :target_banned}) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Target user is banned"})
  end

  def call(conn, {:error, :target_not_in_room}) do
    conn
    |> put_status(403)
    |> json(%{"errcode" => "M_FORBIDDEN", "error" => "Target user is not in room"})
  end

  def call(conn, {:error, {:invalid_alias_format, alias_val}}) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_INVALID_PARAM", "error" => "Invalid alias format: #{alias_val}"})
  end

  def call(conn, {:error, {:bad_canonical_alias, alias_val}}) do
    conn
    |> put_status(400)
    |> json(%{"errcode" => "M_BAD_ALIAS", "error" => "Alias #{alias_val} does not exist or does not point to this room"})
  end

  def call(conn, {:error, _reason}) do
    conn
    |> put_status(500)
    |> json(%{"errcode" => "M_UNKNOWN", "error" => "Internal server error"})
  end

  # Phoenix render_errors integration — called when the router has no matching route
  def render("404.json", _assigns), do: %{"errcode" => "M_NOT_FOUND", "error" => "Not found"}
  def render("500.json", _assigns), do: %{"errcode" => "M_UNKNOWN", "error" => "Internal server error"}
  def render(_, _assigns), do: %{"errcode" => "M_UNKNOWN", "error" => "Internal server error"}
end
