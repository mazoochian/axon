defmodule AxonPush.Dispatcher do
  @moduledoc """
  Dispatches push notifications to registered HTTP pushers after a room event,
  and records a durable `AxonPush.Notifications` ledger row for every joined
  recipient whose push rules say to notify — regardless of whether they have
  a pusher registered, since `GET /_matrix/client/v3/notifications` and the
  live unread badge both need that to exist even for a client that never set
  up push. Fire-and-forget: failures are logged but never propagate to the
  caller.
  """

  require Logger

  import Ecto.Query
  alias AxonCore.{NetworkAddress, Repo}
  alias AxonPush.{Notifications, RuleEvaluator, UserRules}

  @doc "Called after an event is persisted. Runs in a Task so it never blocks RoomProcess."
  def dispatch_event(event, room_id) do
    Task.Supervisor.start_child(AxonPush.TaskSupervisor, fn -> do_dispatch(event, room_id) end)
  end

  @doc """
  Whether `url` is an acceptable HTTP pusher URL: http(s) with the spec's
  `/_matrix/push/v1/notify` path.
  """
  def valid_push_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: "/_matrix/push/v1/notify"}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def valid_push_url?(_url), do: false

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_dispatch(event, room_id) do
    members =
      Repo.all(
        from(m in "room_memberships",
          where: m.room_id == ^room_id and m.membership == "join",
          select: m.user_id
        )
      )

    # Don't push to (or notify) the sender about their own event.
    sender = event["sender"]
    recipients = Enum.reject(members, &(&1 == sender))

    Enum.each(recipients, fn user_id ->
      rules = UserRules.effective_rules(user_id)

      case RuleEvaluator.should_notify?(event, room_id, user_id, rules) do
        {:notify, actions} ->
          Notifications.record(user_id, room_id, event, actions)

          case get_pushers(user_id) do
            [] ->
              :ok

            pushers ->
              tweaks = extract_tweaks(actions)
              Enum.each(pushers, fn pusher -> send_http_push(pusher, event, room_id, tweaks) end)
          end

        :dont_notify ->
          :ok
      end
    end)
  end

  defp get_pushers(user_id) do
    Repo.all(
      from(p in "pushers",
        where: p.user_id == ^user_id and p.enabled == true and p.kind == "http",
        select: %{
          app_id: p.app_id,
          pushkey: p.pushkey,
          data: p.data
        }
      )
    )
  end

  defp extract_tweaks(actions) do
    Enum.reduce(actions, %{}, fn
      %{"set_tweak" => k, "value" => v}, acc -> Map.put(acc, k, v)
      %{"set_tweak" => k}, acc -> Map.put(acc, k, true)
      _, acc -> acc
    end)
  end

  defp send_http_push(pusher, event, room_id, tweaks) do
    data = pusher.data || %{}
    push_url = data["url"]

    case check_push_url(push_url) do
      :ok ->
        payload =
          Jason.encode!(%{"notification" => notification(pusher, data, event, room_id, tweaks)})

        req = Finch.build(:post, push_url, [{"content-type", "application/json"}], payload)

        case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Finch.Response{status: status}} ->
            Logger.warning("Push gateway #{push_url} returned #{status}")

          {:error, reason} ->
            Logger.warning("Push to #{push_url} failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning(
          "Not pushing to #{pusher.app_id}/#{pusher.pushkey} url #{inspect(push_url)}: #{reason}"
        )
    end
  end

  defp notification(pusher, data, event, room_id, tweaks) do
    prio =
      if (event["type"] == "m.room.encrypted" or tweaks["highlight"]) || tweaks["sound"],
        do: "high",
        else: "low"

    base = %{
      "event_id" => event["event_id"],
      "room_id" => room_id,
      "counts" => %{"unread" => 1},
      "prio" => prio,
      "devices" => [
        %{
          "app_id" => pusher.app_id,
          "pushkey" => pusher.pushkey,
          "pushkey_ts" => 0,
          "data" => Map.delete(data, "url"),
          "tweaks" => tweaks
        }
      ]
    }

    if data["format"] == "event_id_only" do
      base
    else
      Map.merge(base, %{
        "type" => event["type"],
        "sender" => event["sender"],
        "content" => event["content"] || %{}
      })
    end
  end

  # `:axon_push, :allow_private_addresses` lifts the private-address block
  # (test suites whose fake gateway listens on loopback).
  defp check_push_url(url) do
    cond do
      not valid_push_url?(url) ->
        {:error, "invalid push url"}

      Application.get_env(:axon_push, :allow_private_addresses, false) ->
        :ok

      true ->
        case NetworkAddress.check(URI.parse(url).host) do
          {:ok, _addresses} -> :ok
          {:error, _} -> {:error, "blocked address"}
        end
    end
  end
end
