# Replayx divide-by-zero demo: real-world non-deterministic crash.
# Run: mix run examples/divide_crash.exs
#
# GenServer divides 10 by a random divisor. First 3 tries use 1–5 (safe);
# from the 4th try onward divisor can be 0–5, so we eventually crash on 0.
# We record until that crash, then replay to reproduce it deterministically.
# Traces: traces/<module_base>_<timestamp>.json

defmodule Replayx.Examples.DivideGenServer do
  @moduledoc """
  Example GenServer: divides 10 by the divisor in the message {:divide, divisor}.
  Caller sends {:divide, n}; first 3 use 1–5 (safe), then 0–5 so we can hit 0.
  Message events (with payload {:divide, divisor}) are recorded so you can see them in the trace.
  """
  use Replayx.GenServer, trace_buffer_size: 50, virtualize: true

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init_impl(_args), do: {:ok, %{divisions: 0, last_divisor: nil}}

  def handle_call_impl(:state, _from, state), do: {:reply, state, state}
  def handle_cast_impl(_msg, state), do: {:noreply, state}

  def handle_info_impl({:divide, divisor}, state) do
    _result = div(10, divisor)
    {:noreply, %{state | divisions: state.divisions + 1, last_divisor: divisor}}
  end

  def handle_info_impl(_msg, state), do: {:noreply, state}
end

# Run demo only when executed directly (mix run), not when loaded for tests.
run_demo? = is_nil(Process.get(:replayx_loading_module)) and Mix.env() != :test

if run_demo? do
  module = Replayx.Examples.DivideGenServer
  trace_dir = module.__replayx_trace_dir__()
  trace_base = module.__replayx_trace_base__()

  IO.puts("=== Divide-by-zero demo: first 3 tries safe (1–5), then 0–5 (crash on 0) ===")
  IO.puts("Recording to #{trace_dir}/#{trace_base}_<timestamp>.json")
  IO.puts("")

  Replayx.record(module, fn recorder_pid ->
    {:ok, pid} = module.start_link(recorder_pid)
    Process.unlink(pid)
    ref = Process.monitor(pid)

    # Build divisors: first 3 from 1..5 (safe), then 0..5 until we get 0.
    # Each {:divide, divisor} is recorded as a message event so you see it in the trace.
    first_three = for _ <- 1..3, do: :rand.uniform(5)

    rest =
      Enum.reduce_while(1..500, [], fn _, acc ->
        d = :rand.uniform(6) - 1
        if d == 0, do: {:halt, acc ++ [0]}, else: {:cont, acc ++ [d]}
      end)

    divisors = first_three ++ rest

    for divisor <- divisors, do: send(pid, {:divide, divisor})

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end)

  IO.puts("Trace written. Replaying to reproduce the crash...")
  IO.puts("")

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
      IO.puts("Division by zero was recorded; replay is deterministic.")
  end

  IO.puts("")
  IO.puts("Done. Run again: mix run examples/divide_crash.exs")
end
