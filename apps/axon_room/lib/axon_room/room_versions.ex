defmodule AxonRoom.RoomVersions do
  @moduledoc "The room versions this server supports, and room-version number comparisons."

  @supported ~w(2 3 4 5 6 7 8 9 10 11 12)

  @doc "Every supported room version string, oldest first."
  def supported, do: @supported

  @doc "Whether `version` is a supported room version string."
  def supported?(version), do: version in @supported

  @doc """
  Whether `version` is a numbered room version `>= min`. Unknown or
  non-numeric versions are never "at least" anything.
  """
  def at_least?(version, min) when is_binary(version) do
    case Integer.parse(version) do
      {n, ""} -> n >= min
      _ -> false
    end
  end

  def at_least?(_version, _min), do: false
end
