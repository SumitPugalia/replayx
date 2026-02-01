# Replayx record/replay demo.
# Run: mix run examples/record_and_replay.exs
#
# Records a short scenario (ticks, roll, state, crash) then replays it.
# Traces: traces/<module_base>_<timestamp>.json

defmodule Replayx.Examples.CrashingGenServer do
  @moduledoc """
  Example GenServer for Replayx record/replay.
  Handles :tick (counter), :roll (virtualized rand), :state (call), and :crash (raises).
  With virtualize: true the library records time once per message automatically; use uniform(n) where you need randomness.
  """
  use Replayx.GenServer, trace_buffer_size: 20, virtualize: true

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init_impl(_args), do: {:ok, %{ticks: 0}}

  def handle_call_impl(:state, _from, state), do: {:reply, state, state}
  def handle_cast_impl(_msg, state), do: {:noreply, state}

  def handle_info_impl(:tick, state) do
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  def handle_info_impl(:roll, state) do
    n = uniform(10)
    {:noreply, Map.put(state, :last_roll, n)}
  end

  def handle_info_impl(:crash, state) do
    IO.puts("\n  [Replayx] State at crash: #{inspect(state)}\n")
    raise "replayx example crash"
  end

  def handle_info_impl(_msg, state), do: {:noreply, state}
end

# For virtualized timers use send_after(ms, pid, msg) in callbacks (injected when virtualize: true).

# Run demo only when executed directly (mix run), not when loaded for tests.
run_demo? = is_nil(Process.get(:replayx_loading_module)) and Mix.env() != :test

if run_demo? do
  module = Replayx.Examples.CrashingGenServer
  trace_dir = module.__replayx_trace_dir__()
  trace_base = module.__replayx_trace_base__()

  IO.puts(
    "=== Recording to #{trace_dir}/#{trace_base}_<timestamp>.json (from #{inspect(module)}) ==="
  )

  IO.puts("Scenario: :tick x3, :roll, :state, :crash. State at crash is logged.")
  IO.puts("")

  Replayx.record(module, fn recorder_pid ->
    {:ok, pid} = module.start_link(recorder_pid)
    send(pid, :tick)
    send(pid, :tick)
    send(pid, :tick)
    send(pid, :roll)
    GenServer.call(pid, :state)
    send(pid, :crash)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    end
  end)

  IO.puts(
    "Trace written to #{trace_dir}/ (timestamped). Replay with: mix replay #{inspect(module)}"
  )

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
