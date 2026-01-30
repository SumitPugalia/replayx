defmodule Mix.Tasks.Replay.Record do
  @shortdoc "Records a trace to the given path (example: CrashingGenServer scenario)"
  @moduledoc """
  Records a trace. Path comes from the module's trace_file or you pass it.

      mix replay.record Replayx.Examples.CrashingGenServer   # uses trace_file from the module
      mix replay.record trace.json Replayx.Examples.CrashingGenServer   # or pass path explicitly

  The module's path is set with `use Replayx.GenServer, trace_file: \"trace.json\"`.
  For Replayx.Examples.CrashingGenServer this runs the built-in scenario (tick, tick, state, crash).
  For other modules record from code: Replayx.record(MyServer, fn recorder_pid -> ... end).
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
          record(path, module)
        else
          module =
            [path | module_name_parts] |> Enum.join(".") |> String.split(".") |> Module.concat()

          ensure_example_loaded!(module)
          path = module.__replayx_trace_file__()
          record(path, module)
        end

      [] ->
        Mix.raise("Usage: mix replay.record [path] <Module.Name>")
    end
  end

  defp ensure_example_loaded!(module) do
    if module == :"Elixir.Replayx.Examples.CrashingGenServer" do
      Process.put(:replayx_loading_module, true)
      Code.require_file("examples/record_and_replay.exs")
      Process.delete(:replayx_loading_module)
    end
  end

  defp record(path, module) do
    if module == :"Elixir.Replayx.Examples.CrashingGenServer" do
      Mix.shell().info("Recording CrashingGenServer scenario to #{path}...")

      Replayx.record(path, fn recorder_pid ->
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

      Mix.shell().info(
        "Trace written to #{path}. Replay with: mix replay Replayx.Examples.CrashingGenServer"
      )
    else
      show_record_help(path)
    end
  end

  defp show_record_help(_path) do
    Mix.shell().info("""
    No built-in scenario for this module. Record from code, e.g. in IEx:

      Replayx.record(YourModule, fn recorder_pid ->
        {:ok, pid} = YourModule.start_link(recorder_pid)
        # ... send messages, call, cast ...
        # Wait for the server to finish before returning (sync call or monitor + receive)
      end)

    (YourModule must use Replayx.GenServer. Then replay with: mix replay YourModule)
    """)
  end
end
