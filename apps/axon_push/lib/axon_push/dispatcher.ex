defmodule AxonPush.Dispatcher do
  @moduledoc """
  Dispatches push notifications to registered HTTP pushers after a room event.
  Fire-and-forget: failures are logged but never propagate to the caller.
  """

  require Logger

  import Ecto.Query
  alias AxonCore.Repo
  alias AxonPush.{DefaultRules, RuleEvaluator}

  @doc "Called after an event is persisted. Runs in a Task so it never blocks RoomProcess."
  def dispatch_event(event, room_id) do
    Task.Supervisor.start_child(AxonPush.TaskSupervisor, fn -> do_dispatch(event, room_id) end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_dispatch(event, room_id) do
    members =
      Repo.all(
        from m in "room_memberships",
          where: m.room_id == ^room_id and m.membership == "join",
          select: m.user_id
      )

    # Don't push to the sender
    sender = event["sender"]
    recipients = Enum.reject(members, &(&1 == sender))

    default_rules = DefaultRules.rules()

    Enum.each(recipients, fn user_id ->
      pushers = get_pushers(user_id)
      if pushers != [] do
        case RuleEvaluator.should_notify?(event, room_id, user_id, default_rules) do
          {:notify, actions} ->
            tweaks = extract_tweaks(actions)
            Enum.each(pushers, fn pusher ->
              send_http_push(pusher, event, room_id, tweaks)
            end)
          :dont_notify ->
            :ok
        end
      end
    end)
  end

  defp get_pushers(user_id) do
    Repo.all(
      from p in "pushers",
        where: p.user_id == ^user_id and p.enabled == true and p.kind == "http",
        select: %{
          app_id: p.app_id,
          pushkey: p.pushkey,
          data: p.data
        }
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
    push_url = get_in(pusher.data, ["url"]) || get_in(pusher.data, [:url])
    if is_nil(push_url) do
      Logger.warning("Pusher #{pusher.app_id}/#{pusher.pushkey} has no url in data")
    else
      payload = Jason.encode!(%{
        "notification" => %{
          "event_id" => event["event_id"],
          "room_id" => room_id,
          "type" => event["type"],
          "sender" => event["sender"],
          "content" => event["content"] || %{},
          "counts" => %{"unread" => 1},
          "devices" => [%{
            "app_id" => pusher.app_id,
            "pushkey" => pusher.pushkey,
            "pushkey_ts" => 0,
            "data" => %{},
            "tweaks" => tweaks
          }]
        }
      })

      req = Finch.build(:post, push_url, [{"content-type", "application/json"}], payload)

      case Finch.request(req, Axon.Finch, receive_timeout: 10_000) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          :ok
        {:ok, %Finch.Response{status: status}} ->
          Logger.warning("Push gateway #{push_url} returned #{status}")
        {:error, reason} ->
          Logger.warning("Push to #{push_url} failed: #{inspect(reason)}")
      end
    end
  end
end
