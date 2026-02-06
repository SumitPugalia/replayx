# Replayx divide-by-zero demo with DynamicSupervisor + TracedServerStarter.
# Run: mix run examples/divide_crash_supervised.exs
#
# Same DivideGenServer as divide_crash.exs, but started under a DynamicSupervisor
# via Replayx.TracedServerStarter (production-style). A "caller" sends {:divide, divisor}
# to the registered server until we hit 0 and crash; the trace is written on crash.
# Then we replay to reproduce.

# Load DivideGenServer without running the other example's demo block
Process.put(:replayx_loading_module, true)
Code.require_file("examples/divide_crash.exs")
Process.delete(:replayx_loading_module)

run_demo? = Mix.env() != :test

if run_demo? do
  module = Replayx.Examples.DivideGenServer
  trace_dir = module.__replayx_trace_dir__()
  trace_base = module.__replayx_trace_base__()

  IO.puts("=== Divide-by-zero with DynamicSupervisor + TracedServerStarter ===")
  IO.puts("Traces: #{trace_dir}/#{trace_base}_<timestamp>.json")
  IO.puts("")

  # 1. Start DynamicSupervisor (as in a real application)
  {:ok, sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

  # 2. Start Recorder + GenServer pair via TracedServerStarter (production helper)
  #    The server is registered by name so other processes can send messages.
  {:ok, starter_pid} =
    Replayx.TracedServerStarter.start_child(
      sup,
      module,
      [],
      name: module
    )

  # 3. Get the GenServer pid (it's registered under the module name)
  server_pid = Process.whereis(module)
  ref_server = Process.monitor(server_pid)
  ref_starter = Process.monitor(starter_pid)

  # 4. "Caller" (in a real app this could be another GenServer, API, or background job)
  #    Build divisors: first 3 from 1..5 (safe), then 0..5 until we get 0.
  first_three = for _ <- 1..3, do: :rand.uniform(5)
  rest =
    Enum.reduce_while(1..500, [], fn _, acc ->
      d = :rand.uniform(6) - 1
      if d == 0, do: {:halt, acc ++ [0]}, else: {:cont, acc ++ [d]}
    end)

  divisors = first_three ++ rest

  for divisor <- divisors do
    send(module, {:divide, divisor})
  end

  # 5. Wait for GenServer to crash
  receive do
    {:DOWN, ^ref_server, :process, ^server_pid, _reason} -> :ok
  end

  # 6. Wait for TracedServerStarter to exit (Recorder flushes trace, then exits)
  receive do
    {:DOWN, ^ref_starter, :process, ^starter_pid, _reason} -> :ok
  after
    3000 -> raise "TracedServerStarter did not exit (trace flush timeout)"
  end

  IO.puts("Trace written. Replaying to reproduce the crash...")
  IO.puts("")

  # 7. Replay (same as mix replay Replayx.Examples.DivideGenServer)
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
  IO.puts("Done. Run again: mix run examples/divide_crash_supervised.exs")
end
