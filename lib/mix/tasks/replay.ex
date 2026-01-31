defmodule Mix.Tasks.Replay do
  @shortdoc "Replays a trace file with the given module"
  @moduledoc """
  Replays a trace file deterministically using the given module.

      mix replay MyApp.MyServer              # replays latest trace for that module (from trace_dir)
      mix replay trace.json MyApp.MyServer  # replays the given trace file

  The module must use Replayx.GenServer and its init must accept
  `[{:replayx_replayer, agent_pid}]` and put `replayx_replayer` in state.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, args, _invalid} =
      OptionParser.parse(args, strict: [validate: :boolean, step: :boolean])

    case args do
      [path | module_name_parts] ->
        module = resolve_module(path, module_name_parts)
        ensure_example_loaded!(module)
        path = resolve_path(path, module_name_parts, module)
        if opts[:validate], do: validate_only(path), else: replay(path, module, opts)

      [] ->
        Mix.raise(
          "Usage: mix replay <Module.Name>  or  mix replay <path.json> <Module.Name>  (optional: --validate, --step)"
        )
    end
  end

  defp resolve_module(path, module_name_parts) do
    if String.ends_with?(path, ".json") or String.ends_with?(path, ".etf") do
      module_name_parts |> Enum.join(".") |> String.split(".") |> Module.concat()
    else
      [path | module_name_parts] |> Enum.join(".") |> String.split(".") |> Module.concat()
    end
  end

  defp resolve_path(path, _module_name_parts, module) do
    if String.ends_with?(path, ".json") or String.ends_with?(path, ".etf") do
      path
    else
      Replayx.trace_path_for_replay(module)
    end
  end

  defp validate_only(path) do
    unless File.exists?(path) do
      Mix.raise("Trace file not found: #{path}")
    end

    case Replayx.Trace.valid?(path) do
      {:ok, :valid} ->
        Mix.shell().info("Trace file is valid: #{path}")

      {:error, reason} ->
        Mix.raise("Trace file invalid: #{inspect(reason)}")
    end
  end

  defp ensure_example_loaded!(module) do
    if module == :"Elixir.Replayx.Examples.CrashingGenServer" do
      Process.put(:replayx_loading_module, true)
      _ = Code.require_file("examples/record_and_replay.exs")
      _ = Process.delete(:replayx_loading_module)
    end
  end

  defp replay(path, module, opts) do
    unless File.exists?(path) do
      Mix.raise("""
      Trace file not found: #{path}

      Record a trace first, for example:

        mix run examples/record_and_replay.exs

      Or in IEx:

        Replayx.record(Replayx.Examples.CrashingGenServer, fn recorder_pid ->
          {:ok, pid} = Replayx.Examples.CrashingGenServer.start_link(recorder_pid)
          send(pid, :tick)
          send(pid, :crash)
        end)

      Then run: mix replay Replayx.Examples.CrashingGenServer  (replays latest)
      Or:       mix replay traces/<file>.json Replayx.Examples.CrashingGenServer
      """)
    end

    {_metadata, events} = Replayx.Trace.read(path)
    summary_lines = Replayx.Trace.summary(events)
    Mix.shell().info("")
    Enum.each(summary_lines, &Mix.shell().info/1)
    Mix.shell().info("")

    replay_opts =
      if opts[:step] do
        [step_fun: step_fun()]
      else
        []
      end

    try do
      case Replayx.replay(path, module, replay_opts) do
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

  defp step_fun do
    fn seq, kind, payload, state ->
      Mix.shell().info("  [step] seq #{seq} | #{kind} | payload: #{inspect(payload)}")
      Mix.shell().info("         state after: #{inspect(state)}")
      line = IO.gets("\n  Press Enter to continue, q+Enter to stop: ") |> String.trim()
      if String.downcase(line) == "q", do: :stop, else: :continue
    end
  end
end
