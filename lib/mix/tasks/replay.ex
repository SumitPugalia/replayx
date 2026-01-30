defmodule Mix.Tasks.Replay do
  @shortdoc "Replays a trace file with the given module"
  @moduledoc """
  Replays a trace file deterministically using the given module.

      mix replay trace.json MyApp.MyServer

  The module must use Replayx.GenServer and its init must accept
  `[{:replayx_replayer, agent_pid}]` and put `replayx_replayer` in state.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {_opts, args, _} = OptionParser.parse(args, strict: [])

    case args do
      [path | module_name_parts] ->
        if String.ends_with?(path, ".json") do
          module = module_name_parts |> Enum.join(".") |> String.split(".") |> Module.concat()
          ensure_example_loaded!(module)
          replay(path, module)
        else
          module =
            [path | module_name_parts] |> Enum.join(".") |> String.split(".") |> Module.concat()

          ensure_example_loaded!(module)
          path = module.__replayx_trace_file__()
          replay(path, module)
        end

      [] ->
        Mix.raise(
          "Usage: mix replay [trace.json] <Module.Name>  (path optional if module has trace_file)"
        )
    end
  end

  defp ensure_example_loaded!(module) do
    if module == :"Elixir.Replayx.Examples.CrashingGenServer" do
      Process.put(:replayx_loading_module, true)
      Code.require_file("examples/record_and_replay.exs")
      Process.delete(:replayx_loading_module)
    end
  end

  defp replay(path, module) do
    unless File.exists?(path) do
      Mix.raise("""
      Trace file not found: #{path}

      Record a trace first, for example in IEx:

        Replayx.record("trace.json", fn recorder_pid ->
          {:ok, pid} = Replayx.Examples.CrashingGenServer.start_link(recorder_pid)
          send(pid, :tick)
          send(pid, :crash)
        end)

      Then run: mix replay trace.json Replayx.Examples.CrashingGenServer
      """)
    end

    try do
      case Replayx.replay(path, module) do
        {:ok, state} ->
          Mix.shell().info("Replay completed. Final state: #{inspect(state)}")

        {:error, reason} ->
          Mix.raise("Replay failed: #{inspect(reason)}")
      end
    rescue
      e ->
        Mix.shell().info("""
        Replay reproduced the crash (same as the original run).

        Why this helps:
        - The crash is now deterministic: run `mix replay #{path} #{inspect(module)}` anytime to hit the same crash.
        - Add logging, IO.inspect, or breakpoints in your GenServer and run replay again to see exactly what led to the crash.
        - No need to reproduce the original timing or message order manually.
        """)

        Mix.shell().info("Exception: #{Exception.message(e)}")
    end
  end
end
