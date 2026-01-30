defmodule Replayx.Clock do
  @moduledoc """
  Virtualized time for record/replay.
  In record mode: calls real functions and records the result.
  In replay mode: returns the next recorded value (no real syscalls).
  """

  @doc """
  Monotonic time. Recorded and replayed.
  """
  @spec monotonic_time(:native | :millisecond | :microsecond | :nanosecond) :: integer()
  def monotonic_time(unit \\ :native) do
    case Process.get(:replayx_recorder) do
      nil ->
        case Process.get(:replayx_replayer) do
          nil ->
            System.monotonic_time(unit)

          agent_pid ->
            pop_and_return(agent_pid, :time_monotonic, &System.monotonic_time/1, [unit])
        end

      recorder_pid ->
        value = System.monotonic_time(unit)
        Replayx.Recorder.record_event(recorder_pid, {:time_monotonic, value})
        value
    end
  end

  @doc """
  System time. Recorded and replayed.
  """
  @spec system_time(:native | :millisecond | :microsecond | :nanosecond) :: integer()
  def system_time(unit \\ :native) do
    case Process.get(:replayx_recorder) do
      nil ->
        case Process.get(:replayx_replayer) do
          nil -> System.system_time(unit)
          agent_pid -> pop_and_return(agent_pid, :time_system, &System.system_time/1, [unit])
        end

      recorder_pid ->
        value = System.system_time(unit)
        Replayx.Recorder.record_event(recorder_pid, {:time_system, value})
        value
    end
  end

  @doc """
  Sends `msg` to `pid` after `delay_ms` milliseconds.
  In record mode: uses real Process.send_after and records ref.
  In replay mode: does not schedule; returns the ref from the trace.
  """
  @spec send_after(non_neg_integer(), pid(), term()) :: reference()
  def send_after(delay_ms, pid, msg) do
    case Process.get(:replayx_recorder) do
      nil ->
        case Process.get(:replayx_replayer) do
          nil -> Process.send_after(pid, msg, delay_ms)
          agent_pid -> pop_send_after_ref(agent_pid)
        end

      recorder_pid ->
        ref = Process.send_after(pid, msg, delay_ms)
        Replayx.Recorder.record_event(recorder_pid, {:send_after, ref, delay_ms})
        ref
    end
  end

  defp pop_and_return(agent_pid, expected_type, real_fun, real_args) do
    case Replayx.ReplayerState.pop(agent_pid) do
      {^expected_type, value} ->
        value

      {other, _} ->
        raise "Replay divergence: expected #{inspect(expected_type)}, got #{inspect(other)}"

      :empty ->
        real_fun.(Enum.at(real_args, 0))
    end
  end

  defp pop_send_after_ref(agent_pid) do
    case Replayx.ReplayerState.pop(agent_pid) do
      {:send_after, ref, _delay_ms} -> ref
      {other, _} -> raise "Replay divergence: expected send_after, got #{inspect(other)}"
      :empty -> raise "Replay divergence: no send_after event"
    end
  end
end
