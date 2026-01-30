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
        module = module_name_parts |> Enum.join(".") |> String.split(".") |> Module.concat()
        replay(path, module)
      [] ->
        Mix.raise("Usage: mix replay <trace.json> <Module.Name>")
    end
  end

  defp replay(path, module) do
    unless File.exists?(path) do
      Mix.raise("Trace file not found: #{path}")
    end

    case Replayx.replay(path, module) do
      {:ok, _state} ->
        Mix.shell().info("Replay completed successfully.")
      {:error, reason} ->
        Mix.raise("Replay failed: #{inspect(reason)}")
    end
  end
end
