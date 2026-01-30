# Single example: Replayx record/replay demo.
# Run with: mix run examples/record_and_replay.exs
#
# Defines Replayx.Examples.CrashingGenServer and runs record + replay.
# Default trace file: replayx_examples_crashinggenserver.json (from module name).

defmodule Replayx.Examples.CrashingGenServer do
  @moduledoc """
  Example GenServer for Replayx record/replay demo.
  Handles :tick (increments counter) and :crash (raises).
  """
  use Replayx.GenServer

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init(args) do
    state = %{ticks: 0}

    state =
      case args do
        [recorder_pid] when is_pid(recorder_pid) ->
          Replayx.Recorder.monitor(recorder_pid, self())
          Map.put(state, :replayx_recorder, recorder_pid)

        [{:replayx_replayer, agent_pid}] ->
          Map.put(state, :replayx_replayer, agent_pid)

        _ ->
          state
      end

    {:ok, state}
  end

  def handle_call_impl(:state, _from, state), do: {:reply, state, state}
  def handle_cast_impl(_msg, state), do: {:noreply, state}

  def handle_info_impl(:tick, state) do
    _ = Replayx.Clock.monotonic_time()
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  def handle_info_impl(:crash, state) do
    IO.puts("\n  [Replayx] State at crash: #{inspect(state)}\n")
    raise "replayx example crash"
  end

  def handle_info_impl(_msg, state), do: {:noreply, state}
end

# Run the demo only when this file is executed (mix run), not when required for tests/Mix tasks.
run_demo? = is_nil(Process.get(:replayx_loading_module)) and Mix.env() != :test

if run_demo? do
  module = Replayx.Examples.CrashingGenServer
  trace_path = module.__replayx_trace_file__()

  IO.puts("=== Recording to #{trace_path} (from #{inspect(module)}) ===")
  IO.puts("Scenario: :tick, :tick, :state, then :crash. State at crash will be logged.")
  IO.puts("")

  Replayx.record(module, fn recorder_pid ->
    {:ok, pid} = module.start_link(recorder_pid)
    send(pid, :tick)
    send(pid, :tick)
    GenServer.call(pid, :state)
    send(pid, :crash)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end)

  IO.puts("Trace written to #{trace_path}")
  IO.puts("")
  IO.puts("=== Replaying ===")

  result =
    try do
      Replayx.replay(module)
    rescue
      e -> {:error, e}
    end

  case result do
    {:ok, state} ->
      IO.puts("Replay completed. Final state: #{inspect(state)}")

    {:error, %{message: msg}} ->
      IO.puts("Replay reproduced the crash: #{msg}")
      IO.puts("")

      IO.puts(
        "Above you saw '[Replayx] State at crash: ...' — the GenServer state when :crash was handled."
      )
  end

  IO.puts("")
  IO.puts("Done. Run again: mix run examples/record_and_replay.exs")
end
