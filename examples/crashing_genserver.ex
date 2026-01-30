# Example: instrumented GenServer that can crash. Use for record/replay demo.
#
# Record:
#   Replayx.record("trace.json", fn recorder_pid ->
#     {:ok, pid} = Replayx.Examples.CrashingGenServer.start_link(recorder_pid)
#     send(pid, :tick)
#     send(pid, :tick)
#     send(pid, :crash)
#   end)
#
# Replay:
#   mix replay trace.json Replayx.Examples.CrashingGenServer

defmodule Replayx.Examples.CrashingGenServer do
  use Replayx.GenServer

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init(args) do
    state = %{ticks: 0}
    state =
      case args do
        [recorder_pid] when is_pid(recorder_pid) ->
          Map.put(state, :replayx_recorder, recorder_pid)
        [{:replayx_replayer, agent_pid}] ->
          Map.put(state, :replayx_replayer, agent_pid)
        _ ->
          state
      end
    {:ok, state}
  end

  def handle_call_impl(:state, _from, state) do
    {:reply, state, state}
  end

  def handle_cast_impl(_msg, state) do
    {:noreply, state}
  end

  def handle_info_impl(:tick, state) do
    _ = Replayx.Clock.monotonic_time()
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  def handle_info_impl(:crash, _state) do
    raise "replayx example crash"
  end

  def handle_info_impl(_msg, state) do
    {:noreply, state}
  end
end
