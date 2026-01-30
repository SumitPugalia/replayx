defmodule Replayx.ReplayerState do
  @moduledoc """
  Agent holding the remaining trace events for replay.
  Events are consumed in order; type is checked when popping.
  """

  use Agent

  @doc """
  Starts an agent with the given list of events (remaining tail first is ok; we consume from head).
  """
  @spec start_link([Replayx.Trace.event()]) :: Agent.on_start()
  def start_link(events) do
    Agent.start_link(fn -> %{events: events} end)
  end

  @doc """
  Pops the next event. Returns {event_type, value} or :empty.
  Event type is one of :message, :time_monotonic, :time_system, :rand, :rand_seed, :send_after.
  For :message the value is {seq, from, payload}.
  """
  @spec pop(pid()) :: {atom(), term()} | :empty
  def pop(agent_pid) do
    Agent.get_and_update(agent_pid, fn state ->
      case state.events do
        [] -> {:empty, state}
        [event | rest] ->
          {type, value} = event_to_type_value(event)
          {{type, value}, %{state | events: rest}}
      end
    end)
  end

  @doc """
  Pops the next event and asserts it is a message. Returns {seq, kind, from, payload}.
  """
  @spec pop_message(pid()) :: {non_neg_integer(), :call | :cast | :info, term(), term()} | :empty
  def pop_message(agent_pid) do
    case pop(agent_pid) do
      {:message, {seq, kind, from, payload}} -> {seq, kind, from, payload}
      :empty -> :empty
      {other, _} -> raise "Replay: expected message event, got #{inspect(other)}"
    end
  end

  defp event_to_type_value({:message, seq, kind, from, payload}), do: {:message, {seq, kind, from, payload}}
  defp event_to_type_value({:time_monotonic, v}), do: {:time_monotonic, v}
  defp event_to_type_value({:time_system, v}), do: {:time_system, v}
  defp event_to_type_value({:rand, v}), do: {:rand, v}
  defp event_to_type_value({:rand_seed, s}), do: {:rand_seed, s}
  defp event_to_type_value({:send_after, ref, d}), do: {:send_after, {ref, d}}
end
